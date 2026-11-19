// GlobeView.h — the Metal-backed globe view and its Objective-C surface.
//
// The render thread advances the camera and rewrites the satellite point
// buffers from the two most recent snapshots; everything else (input, picking,
// selection) happens on the main thread and talks to the render thread only
// through the camera rig's lock and the snapshot buffer.

#pragma once

#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>

#include <map>
#include <vector>

#include "../Core/Propagation/PropagationEngine.hpp"

@class CaelusGlobeView;

@protocol CaelusGlobeViewDelegate <NSObject>
- (void)globeView:(CaelusGlobeView*)view didSelectIndex:(NSInteger)index;
- (void)globeView:(CaelusGlobeView*)view didHoverIndex:(NSInteger)index;
- (void)globeView:(CaelusGlobeView*)view didRequestFocusLatitude:(double)latitude
        longitude:(double)longitude;
- (void)globeViewDidRequestReset:(CaelusGlobeView*)view;
@end

@interface CaelusGlobeView : MTKView

@property(nonatomic, weak) id<CaelusGlobeViewDelegate> globeDelegate;
@property(nonatomic, assign) double pointRadius;

// One point buffer per render group, sized from the catalog.
- (void)rebuildLayers:(const std::map<caelus::SatelliteGroup, std::vector<size_t>>&)renderIndices;
- (void)setGroup:(caelus::SatelliteGroup)group visible:(BOOL)visible;
- (void)setPointRadius:(double)radius;

// The buffer is owned by the controller and outlives the view.
- (void)attachSnapshotBuffer:(caelus::SnapshotBuffer*)buffer;

- (void)setObserverSite:(const caelus::ObserverSite&)site;
- (void)setObserverVisible:(BOOL)visible;

- (void)updateTrackSamples:(const std::vector<caelus::TrackSample>&)samples
                     color:(NSColor*)color
                 showOrbit:(BOOL)showOrbit
                showGround:(BOOL)showGround;
- (void)clearTrack;

- (void)setSelectionPosition:(const caelus::sky::Vec3&)position
                       valid:(BOOL)valid
                       color:(NSColor*)color;

- (void)focusLatitude:(double)latitude longitude:(double)longitude distance:(float)distance;
- (void)resetCamera;
- (float)cameraDistance;

// Renders one frame at drawable resolution into a texture-backed image.
- (NSImage*)snapshotImage;

@end
