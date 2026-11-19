// AppController.h — the application's model and window wiring.
//
// Translated from the Swift app's AppModel + ContentView. It owns the catalog,
// the propagation engine and the globe, runs the one-hertz tick, and persists
// the handful of preferences a returning user expects to find unchanged.

#pragma once

#import <Cocoa/Cocoa.h>

#include <set>
#include <vector>

#include "../Core/Data/Models.hpp"
#include "../Core/Data/SatelliteCatalog.hpp"

@class CaelusGlobeView;

typedef NS_ENUM(NSInteger, CaelusLoadState) {
    CaelusLoadStateIdle = 0,
    CaelusLoadStateLoading = 1,
    CaelusLoadStateReady = 2,
    CaelusLoadStateFailed = 3,
};

@interface AppController : NSObject

@property(nonatomic, readonly) CaelusGlobeView* globeView;

// Build the window's view hierarchy and start loading.
- (void)installInWindow:(NSWindow*)window;

// Apply any CAELUS_SNAPSHOT* environment hooks.
- (void)captureSnapshotIfRequested;

// MARK: Model access for the tests and the UI layer

- (NSUInteger)catalogCount;
- (BOOL)isFavorite:(int)satelliteID;
- (void)selectIndex:(NSInteger)index;
- (NSInteger)selectedIndex;

// MARK: Actions

- (void)refreshCatalog:(id)sender;
- (void)resetCamera:(id)sender;
- (void)toggleOrbitPath:(id)sender;
- (void)toggleGroundTrack:(id)sender;
- (void)toggleObserver:(id)sender;
- (void)focusSearch:(id)sender;
- (void)toggleFavoriteSelection:(id)sender;
- (void)clearSelection:(id)sender;
- (void)toggleAllGroups:(id)sender;
- (void)saveImage:(id)sender;
- (void)showSettings:(id)sender;

@end
