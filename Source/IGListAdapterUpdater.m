/**
 * Copyright (c) 2016-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "IGListAdapterUpdater.h"
#import "IGListAdapterUpdaterInternal.h"

#import <IGListKit/IGListAssert.h>
#import <IGListKit/IGListBatchUpdateData.h>
#import <IGListKit/IGListDiff.h>

#import "UICollectionView+IGListBatchUpdateData.h"
#import "IGListMoveIndexPathInternal.h"

@implementation IGListAdapterUpdater

- (instancetype)init {
    IGAssertMainThread();

    if (self = [super init]) {
        // the default is to use animations unless NO is passed
        _queuedUpdateIsAnimated = YES;

        _completionBlocks = [NSMutableArray new];
        _itemUpdateBlocks = [NSMutableArray new];

        _batchUpdatesCollector = [IGListBatchUpdates new];

        _allowsBackgroundReloading = YES;
    }
    return self;
}


#pragma mark - Private API

- (BOOL)hasChanges {
    return self.hasQueuedReloadData
    || self.itemUpdateBlocks.count > 0
    || self.fromObjects != nil
    || self.toObjects != nil;
}

- (void)performReloadDataWithCollectionView:(UICollectionView *)collectionView {
    IGAssertMainThread();

    // bail early if the collection view has been deallocated in the time since the update was queued
    if (collectionView == nil) {
        return;
    }

    id<IGListAdapterUpdaterDelegate> delegate = self.delegate;
    void (^reloadUpdates)() = self.reloadUpdates;
    NSArray *completionBlocks = [self.completionBlocks copy];
    NSArray *itemUpdateBlocks = [self.itemUpdateBlocks copy];

    // item updates must not send mutations to the collection view while we are reloading
    self.state = IGListBatchUpdateStateExecutingBatchUpdateBlock;

    if (reloadUpdates) {
        reloadUpdates();
    }

    // execute all stored item update blocks even if we are just calling reloadData. the actual collection view
    // mutations will be discarded, but clients are encouraged to put their actually /data/ mutations inside the
    // update block as well, so if we don't execute the block the changes will never happen
    for (IGListItemUpdateBlock itemUpdateBlock in itemUpdateBlocks) {
        itemUpdateBlock();
    }
    
    self.state = IGListBatchUpdateStateExecutedBatchUpdateBlock;

    // cleanup state before reloading and calling completion blocks
    [self cleanupState];
    [self cleanupUpdateBlockState];

    [delegate listAdapterUpdater:self willReloadDataWithCollectionView:collectionView];
    [collectionView reloadData];
    [collectionView.collectionViewLayout invalidateLayout];
    [collectionView layoutIfNeeded];
    [delegate listAdapterUpdater:self didReloadDataWithCollectionView:collectionView];

    for (IGListUpdatingCompletion block in completionBlocks) {
        block(YES);
    }
    
    self.state = IGListBatchUpdateStateIdle;
}

static NSArray *objectsWithDuplicateIdentifiersRemoved(NSArray<id<IGListDiffable>> *objects) {
    NSMutableSet *identifiers = [NSMutableSet new];
    NSMutableArray *uniqueObjects = [NSMutableArray new];
    for (id<IGListDiffable> object in objects) {
        id diffIdentifier = [object diffIdentifier];
        if (![identifiers containsObject:diffIdentifier]) {
            [identifiers addObject:diffIdentifier];
            [uniqueObjects addObject:object];
        } else {
            IGLKLog(@"WARNING: Object %@ already appeared in objects array", object);
        }
    }
    return uniqueObjects;
}

- (void)performBatchUpdatesWithCollectionView:(UICollectionView *)collectionView {
    IGAssertMainThread();
    IGAssert(self.state == IGListBatchUpdateStateIdle, @"Should not call batch updates when state isn't idle");

    // bail early if the collection view has been deallocated in the time since the update was queued
    if (collectionView == nil) {
        return;
    }

    // create local variables so we can immediately clean our state but pass these items into the batch update block
    id<IGListAdapterUpdaterDelegate> delegate = self.delegate;
    NSArray *fromObjects = [self.fromObjects copy];
    NSArray *toObjects = objectsWithDuplicateIdentifiersRemoved(self.toObjects);
    void (^objectTransitionBlock)(NSArray *) = [self.objectTransitionBlock copy];
    NSArray *itemUpdateBlocks = [self.itemUpdateBlocks copy];
    NSArray *completionBlocks = [self.completionBlocks copy];
    const BOOL animated = self.queuedUpdateIsAnimated;

    // clean up all state so that new updates can be coalesced while the current update is in flight
    [self cleanupState];

    void (^executeUpdateBlocks)() = ^{
        self.state = IGListBatchUpdateStateExecutingBatchUpdateBlock;
        
        // run the update block so that the adapter can set its items. this makes sure that just before the update is
        // committed that the data source is updated to the /latest/ "toObjects". this makes the data source in sync
        // with the items that the updater is transitioning to
        if (objectTransitionBlock != nil) {
            objectTransitionBlock(toObjects);
        }

        // execute each item update block which should make calls like insert, delete, and reload for index paths
        // we collect all mutations in corresponding sets on self, then filter based on UICollectionView shortcomings
        // call after the objectTransitionBlock so section level mutations happen before any items
        for (IGListItemUpdateBlock itemUpdateBlock in itemUpdateBlocks) {
            itemUpdateBlock();
        }
        
        self.state = IGListBatchUpdateStateExecutedBatchUpdateBlock;
    };

    void (^executeCompletionBlocks)(BOOL) = ^(BOOL finished) {
        self.state = IGListBatchUpdateStateIdle;
        
        for (IGListUpdatingCompletion block in completionBlocks) {
            block(finished);
        }
    };

    // if the collection view isn't in a visible window, skip diffing and batch updating. execute all transition blocks,
    // reload data, execute completion blocks, and get outta here
    const BOOL iOS83OrLater = (NSFoundationVersionNumber >= NSFoundationVersionNumber_iOS_8_3);
    if (iOS83OrLater && self.allowsBackgroundReloading && collectionView.window == nil) {
        [self beginPerformBatchUpdatesToObjects:toObjects];
        executeUpdateBlocks();
        [self cleanupUpdateBlockState];
        [self performBatchUpdatesItemBlockApplied];
        [collectionView reloadData];
        executeCompletionBlocks(YES);
        return;
    }

    IGListIndexSetResult *result = IGListDiffExperiment(fromObjects, toObjects, IGListDiffEquality, self.experiments);

    // if the diff has no changes and there are no update blocks queued, dont batch update
    if (!result.hasChanges && itemUpdateBlocks.count == 0) {
        executeUpdateBlocks();
        executeCompletionBlocks(YES);
        return;
    }

    __block IGListBatchUpdateData *updateData = nil;

    void (^updateBlock)() = ^{
        executeUpdateBlocks();

        updateData = [self flushCollectionView:collectionView
                                withDiffResult:result
                         batchUpdatesCollector:self.batchUpdatesCollector
                                   fromObjects:fromObjects];

        [self cleanupUpdateBlockState];
        [self performBatchUpdatesItemBlockApplied];
    };

    void (^completionBlock)(BOOL) = ^(BOOL finished) {
        executeCompletionBlocks(finished);

        [delegate listAdapterUpdater:self didPerformBatchUpdates:updateData collectionView:collectionView];

        // queue another update in case something changed during batch updates. this method will bail next runloop if
        // there are no changes
        [self queueUpdateWithCollectionView:collectionView];
    };

    // disables multiple performBatchUpdates: from happening at the same time
    [self beginPerformBatchUpdatesToObjects:toObjects];

    @try {
        [delegate listAdapterUpdater:self willPerformBatchUpdatesWithCollectionView:collectionView];
        if (animated) {
            [collectionView performBatchUpdates:updateBlock completion:completionBlock];
        } else {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [collectionView performBatchUpdates:updateBlock completion:^(BOOL finished) {
                completionBlock(finished);
                [CATransaction commit];
            }];
        }
    } @catch (NSException *exception) {
        [delegate listAdapterUpdater:self willCrashWithException:exception fromObjects:fromObjects toObjects:toObjects updates:updateData];
        @throw exception;
    }
}

void convertReloadToDeleteInsert(NSMutableIndexSet *reloads,
                                 NSMutableIndexSet *deletes,
                                 NSMutableIndexSet *inserts,
                                 IGListIndexSetResult *result,
                                 NSArray<id<IGListDiffable>> *fromObjects) {
    // reloadSections: is unsafe to use within performBatchUpdates:, so instead convert all reloads into deletes+inserts
    const BOOL hasObjects = [fromObjects count] > 0;
    [[reloads copy] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        // if a diff was not performed, there are no changes. instead use the same index that was originally queued
        id<NSObject> diffIdentifier = hasObjects ? [fromObjects[idx] diffIdentifier] : nil;
        const NSInteger from = hasObjects ? [result oldIndexForIdentifier:diffIdentifier] : idx;
        const NSInteger to = hasObjects ? [result newIndexForIdentifier:diffIdentifier] : idx;
        [reloads removeIndex:from];

        // if a reload is queued outside the diff and the object was inserted or deleted it cannot be
        if (from != NSNotFound && to != NSNotFound) {
            [deletes addIndex:from];
            [inserts addIndex:to];
        } else {
            IGAssert([result.deletes containsIndex:idx],
                     @"Reloaded section %zi was not found in deletes with from: %zi, to: %zi, deletes: %@",
                     idx, from, to, deletes);
        }
    }];
}

- (IGListBatchUpdateData *)flushCollectionView:(UICollectionView *)collectionView
                                withDiffResult:(IGListIndexSetResult *)diffResult
                         batchUpdatesCollector:(IGListBatchUpdates *)batchUpdatesCollector
                                   fromObjects:(NSArray <id<IGListDiffable>> *)fromObjects {
    NSSet *moves = [[NSSet alloc] initWithArray:diffResult.moves];

    // combine section reloads from the diff and manual reloads via reloadItems:
    NSMutableIndexSet *reloads = [diffResult.updates mutableCopy];
    [reloads addIndexes:batchUpdatesCollector.sectionReloads];

    NSMutableIndexSet *inserts = [diffResult.inserts mutableCopy];
    NSMutableIndexSet *deletes = [diffResult.deletes mutableCopy];
    if (self.movesAsDeletesInserts) {
        for (IGListMoveIndex *move in moves) {
            [deletes addIndex:move.from];
            [inserts addIndex:move.to];
        }
        // clear out all moves
        moves = [NSSet new];
    }

    // reloadSections: is unsafe to use within performBatchUpdates:, so instead convert all reloads into deletes+inserts
    convertReloadToDeleteInsert(reloads, deletes, inserts, diffResult, fromObjects);

    IGListBatchUpdateData *updateData = [[IGListBatchUpdateData alloc] initWithInsertSections:inserts
                                                                               deleteSections:deletes
                                                                                 moveSections:moves
                                                                             insertIndexPaths:batchUpdatesCollector.itemInserts
                                                                             deleteIndexPaths:batchUpdatesCollector.itemDeletes
                                                                               moveIndexPaths:batchUpdatesCollector.itemMoves
                                                                             reloadIndexPaths:batchUpdatesCollector.itemReloads];
    [collectionView ig_applyBatchUpdateData:updateData];
    return updateData;
}

- (void)beginPerformBatchUpdatesToObjects:(NSArray *)toObjects {
    self.pendingTransitionToObjects = toObjects;
    self.state = IGListBatchUpdateStateQueuedBatchUpdate;
}

- (void)performBatchUpdatesItemBlockApplied {
    self.pendingTransitionToObjects = nil;
}

- (void)cleanupState {
    self.queuedUpdateIsAnimated = YES;

    // destroy to/from transition items
    self.fromObjects = nil;
    self.toObjects = nil;

    // destroy reloadData state
    self.reloadUpdates = nil;
    self.queuedReloadData = NO;

    // remove indexpath/item changes
    self.objectTransitionBlock = nil;
    [self.itemUpdateBlocks removeAllObjects];

    // remove completion blocks from item transitions or index path updates
    [self.completionBlocks removeAllObjects];
}

- (void)cleanupUpdateBlockState {
    self.batchUpdatesCollector = [IGListBatchUpdates new];
}

- (void)queueUpdateWithCollectionView:(UICollectionView *)collectionView {
    IGAssertMainThread();

    // callers may hold weak refs and lose the collection view by the time we requeue, bail if that's the case
    if (collectionView == nil) {
        return;
    }

    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.state != IGListBatchUpdateStateIdle
            || ![weakSelf hasChanges]) {
            return;
        }

        if (weakSelf.hasQueuedReloadData) {
            [weakSelf performReloadDataWithCollectionView:collectionView];
        } else {
            [weakSelf performBatchUpdatesWithCollectionView:collectionView];
        }
    });
}


#pragma mark - IGListUpdatingDelegate

static BOOL IGListIsEqual(const void *a, const void *b, NSUInteger (*size)(const void *item)) {
    const id<IGListDiffable> left = (__bridge id<IGListDiffable>)a;
    const id<IGListDiffable> right = (__bridge id<IGListDiffable>)b;
    return [[left diffIdentifier] isEqual:[right diffIdentifier]];
}

// since the diffing algo used in this updater keys items based on their -diffIdentifier, we must use a map table that
// precisely mimics this behavior
static NSUInteger IGListIdentifierHash(const void *item, NSUInteger (*size)(const void *item)) {
    return [[(__bridge id<IGListDiffable>)item diffIdentifier] hash];
}

- (NSPointerFunctions *)objectLookupPointerFunctions {
    NSPointerFunctions *functions = [NSPointerFunctions pointerFunctionsWithOptions:NSPointerFunctionsStrongMemory];
    functions.hashFunction = IGListIdentifierHash;
    functions.isEqualFunction = IGListIsEqual;
    return functions;
}

- (void)performUpdateWithCollectionView:(UICollectionView *)collectionView
                            fromObjects:(nullable NSArray *)fromObjects
                              toObjects:(nullable NSArray *)toObjects
                               animated:(BOOL)animated
                  objectTransitionBlock:(void (^)(NSArray *))objectTransitionBlock
                             completion:(nullable void (^)(BOOL))completion {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(objectTransitionBlock != nil);

    // only update the items that we are coming from if it has not been set
    // this allows multiple updates to be called while an update is already in progress, and the transition from > to
    // will be done on the first "fromObjects" received and the last "toObjects"
    // if performBatchUpdates: hasn't applied the update block, then data source hasn't transitioned its state. if an
    // update is queued in between then we must use the pending toObjects
    self.fromObjects = self.fromObjects ?: self.pendingTransitionToObjects ?: fromObjects;
    self.toObjects = toObjects;

    // disabled animations will always take priority
    // reset to YES in -cleanupState
    self.queuedUpdateIsAnimated = self.queuedUpdateIsAnimated && animated;

#ifdef DEBUG
    for (id obj in toObjects) {
        IGAssert([obj conformsToProtocol:@protocol(IGListDiffable)],
                 @"In order to use IGListAdapterUpdater, object %@ must conform to IGListDiffable", obj);
    }
#endif

    // always use the last update block, even though this should always do the exact same thing
    self.objectTransitionBlock = objectTransitionBlock;

    IGListUpdatingCompletion localCompletion = completion;
    if (localCompletion) {
        [self.completionBlocks addObject:localCompletion];
    }

    [self queueUpdateWithCollectionView:collectionView];
}

- (void)performUpdateWithCollectionView:(UICollectionView *)collectionView
                               animated:(BOOL)animated
                            itemUpdates:(void (^)())itemUpdates
                             completion:(void (^)(BOOL))completion {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(itemUpdates != nil);

    // disabled animations will always take priority
    // reset to YES in -cleanupState
    self.queuedUpdateIsAnimated = self.queuedUpdateIsAnimated && animated;

    [self.itemUpdateBlocks addObject:itemUpdates];

    if (completion != nil) {
        [self.completionBlocks addObject:completion];
    }

    [self queueUpdateWithCollectionView:collectionView];
}

- (void)insertItemsIntoCollectionView:(UICollectionView *)collectionView indexPaths:(NSArray <NSIndexPath *> *)indexPaths {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(indexPaths != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdatesCollector.itemInserts addObjectsFromArray:indexPaths];
    } else {
        [self.delegate listAdapterUpdater:self willInsertIndexPaths:indexPaths collectionView:collectionView];
        [collectionView insertItemsAtIndexPaths:indexPaths];
    }
}

- (void)deleteItemsFromCollectionView:(UICollectionView *)collectionView indexPaths:(NSArray <NSIndexPath *> *)indexPaths {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(indexPaths != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdatesCollector.itemDeletes addObjectsFromArray:indexPaths];
    } else {
        [self.delegate listAdapterUpdater:self willDeleteIndexPaths:indexPaths collectionView:collectionView];
        [collectionView deleteItemsAtIndexPaths:indexPaths];
    }
}

- (void)moveItemInCollectionView:(UICollectionView *)collectionView
                   fromIndexPath:(NSIndexPath *)fromIndexPath
                     toIndexPath:(NSIndexPath *)toIndexPath {
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        IGListMoveIndexPath *move = [[IGListMoveIndexPath alloc] initWithFrom:fromIndexPath to:toIndexPath];
        [self.batchUpdatesCollector.itemMoves addObject:move];
    } else {
        [self.delegate listAdapterUpdater:self willMoveFromIndexPath:fromIndexPath toIndexPath:toIndexPath collectionView:collectionView];
        [collectionView moveItemAtIndexPath:fromIndexPath toIndexPath:toIndexPath];
    }
}

- (void)reloadItemsInCollectionView:(UICollectionView *)collectionView indexPaths:(NSArray <NSIndexPath *> *)indexPaths {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(indexPaths != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdatesCollector.itemReloads addObjectsFromArray:indexPaths];
    } else {
        [self.delegate listAdapterUpdater:self willReloadIndexPaths:indexPaths collectionView:collectionView];
        [collectionView reloadItemsAtIndexPaths:indexPaths];
    }
}

- (void)reloadDataWithCollectionView:(UICollectionView *)collectionView
                   reloadUpdateBlock:(IGListReloadUpdateBlock)reloadUpdateBlock
                          completion:(nullable IGListUpdatingCompletion)completion {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(reloadUpdateBlock != nil);

    IGListUpdatingCompletion localCompletion = completion;
    if (localCompletion) {
        [self.completionBlocks addObject:localCompletion];
    }

    self.reloadUpdates = reloadUpdateBlock;
    self.queuedReloadData = YES;
    [self queueUpdateWithCollectionView:collectionView];
}

- (void)reloadCollectionView:(UICollectionView *)collectionView sections:(NSIndexSet *)sections {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(sections != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdatesCollector.sectionReloads addIndexes:sections];
    } else {
        [self.delegate listAdapterUpdater:self willReloadSections:sections collectionView:collectionView];
        [collectionView reloadSections:sections];
    }
}

@end
