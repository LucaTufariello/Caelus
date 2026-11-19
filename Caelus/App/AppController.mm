#import "AppController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "GlobeView.h"
#import "URLSessionHttpClient.hpp"

#include "Data/CacheStore.hpp"
#include "Data/CatalogService.hpp"
#include "Data/CelesTrakClient.hpp"
#include "Data/Models.hpp"
#include "Propagation/PropagationEngine.hpp"
#include "Data/SatelliteCatalog.hpp"
#include "Propagation/SunCalculator.hpp"
#include "Data/SyntheticCatalog.hpp"
#include "Sky/TimeUtil.hpp"

#include <cmath>
#include <ctime>
#include <memory>
#include <set>
#include <string>
#include <vector>

// MARK: - Theme

static NSColor* ThemeBackground() { return [NSColor colorWithSRGBRed:0.024 green:0.035 blue:0.055 alpha:1]; }
static NSColor* ThemeSurface() { return [NSColor colorWithSRGBRed:0.039 green:0.055 blue:0.082 alpha:1]; }
static NSColor* ThemeRaised() { return [NSColor colorWithSRGBRed:0.063 green:0.086 blue:0.122 alpha:1]; }
static NSColor* ThemeTextPrimary() { return [NSColor colorWithSRGBRed:0.910 green:0.929 blue:0.961 alpha:1]; }
static NSColor* ThemeTextSecondary() { return [NSColor colorWithSRGBRed:0.545 green:0.596 blue:0.667 alpha:1]; }
static NSColor* ThemeTextTertiary() { return [NSColor colorWithSRGBRed:0.353 green:0.408 blue:0.471 alpha:1]; }
static NSColor* ThemeAccent() { return [NSColor colorWithSRGBRed:0.310 green:0.702 blue:1.0 alpha:1]; }
static NSColor* ThemeWarning() { return [NSColor colorWithSRGBRed:1.0 green:0.706 blue:0.329 alpha:1]; }
static NSColor* ThemeSuccess() { return [NSColor colorWithSRGBRed:0.239 green:0.863 blue:0.592 alpha:1]; }
static NSColor* ThemeScience() { return [NSColor colorWithSRGBRed:0.710 green:0.549 blue:1.0 alpha:1]; }

static NSColor* GroupColor(caelus::SatelliteGroup group) {
    switch (group) {
        case caelus::SatelliteGroup::stations: return ThemeTextPrimary();
        case caelus::SatelliteGroup::starlink: return [NSColor colorWithSRGBRed:0.302 green:0.608 blue:1.0 alpha:1];
        case caelus::SatelliteGroup::navigation: return ThemeSuccess();
        case caelus::SatelliteGroup::weather: return ThemeWarning();
        case caelus::SatelliteGroup::science: return ThemeScience();
        case caelus::SatelliteGroup::other: return ThemeTextSecondary();
    }
    return ThemeTextSecondary();
}

static NSString* StdString(const std::string& text) {
    NSString* result = [NSString stringWithUTF8String:text.c_str()];
    return result != nil ? result : @"";
}

static NSString* ShortGroupName(caelus::SatelliteGroup group) {
    switch (group) {
        case caelus::SatelliteGroup::stations: return @"STATION";
        case caelus::SatelliteGroup::starlink: return @"STARLINK";
        case caelus::SatelliteGroup::navigation: return @"NAV";
        case caelus::SatelliteGroup::weather: return @"WEATHER";
        case caelus::SatelliteGroup::science: return @"SCIENCE";
        case caelus::SatelliteGroup::other: return @"OTHER";
    }
    return @"OTHER";
}

static NSDateFormatter* ClockFormatter(void) {
    static NSDateFormatter* formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss";
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    });
    return formatter;
}

static NSDateFormatter* DayTimeFormatter(void) {
    static NSDateFormatter* formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"EEE HH:mm";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_GB"];
    });
    return formatter;
}

static NSString* ClockString(caelus::Date date) {
    return [ClockFormatter() stringFromDate:[NSDate dateWithTimeIntervalSince1970:date]];
}

static NSString* DayTimeString(caelus::Date date) {
    return [DayTimeFormatter() stringFromDate:[NSDate dateWithTimeIntervalSince1970:date]];
}

static NSString* ProvenanceTitle(caelus::DataProvenance provenance) {
    switch (provenance) {
        case caelus::DataProvenance::celestrak: return @"LIVE";
        case caelus::DataProvenance::satnogs: return @"SATNOGS";
        case caelus::DataProvenance::cache: return @"CACHED";
        case caelus::DataProvenance::synthetic: return @"SYNTHETIC";
        case caelus::DataProvenance::none: return @"OFFLINE";
    }
    return @"OFFLINE";
}

static NSColor* ProvenanceColor(caelus::DataProvenance provenance) {
    switch (provenance) {
        case caelus::DataProvenance::celestrak: return ThemeSuccess();
        case caelus::DataProvenance::satnogs: return ThemeWarning();
        case caelus::DataProvenance::cache: return ThemeTextSecondary();
        case caelus::DataProvenance::synthetic: return ThemeScience();
        case caelus::DataProvenance::none: return ThemeWarning();
    }
    return ThemeWarning();
}

static NSString* AltitudeClass(bool hasRecord, const caelus::SatelliteRecord& record) {
    if (!hasRecord) return @"—";
    if (record.perigeeKm() > 30000) return @"GEO";
    if (record.apogeeKm() > 30000) return @"HIGH";
    if (record.apogeeKm() > 2000) return @"MEO";
    return @"LEO";
}

static void StartupMark(NSString* message) {
    static BOOL enabled = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString* value = NSProcessInfo.processInfo.environment[@"CAELUS_STARTUP_LOG"];
        enabled = value != nil && ![value isEqualToString:@"0"];
    });
    if (!enabled) return;
    const NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime;
    NSLog(@"Caelus startup: %@ (%.3f s since boot)", message, elapsed);
}

// MARK: - Small views

@interface CaelusPill : NSView
@property(nonatomic, strong) NSTextField* label;
- (void)setText:(NSString*)text color:(NSColor*)color;
@end

@implementation CaelusPill

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8;
        _label = [NSTextField labelWithString:@""];
        _label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintEqualToConstant:20],
        ]];
    }
    return self;
}

- (void)setText:(NSString*)text color:(NSColor*)color {
    self.label.stringValue = text;
    self.label.textColor = color;
    self.layer.backgroundColor = [color colorWithAlphaComponent:0.14].CGColor;
    self.hidden = text.length == 0;
}

@end

@interface CaelusRowCell : NSTableCellView
@property(nonatomic, strong) NSView* dot;
@property(nonatomic, strong) NSTextField* nameLabel;
@property(nonatomic, strong) NSTextField* detailLabel;
@property(nonatomic, strong) NSTextField* altitudeLabel;
@property(nonatomic, strong) NSButton* starButton;
@end

@implementation CaelusRowCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _dot = [[NSView alloc] initWithFrame:NSZeroRect];
        _dot.wantsLayer = YES;
        _dot.layer.cornerRadius = 3.5;
        _dot.translatesAutoresizingMaskIntoConstraints = NO;

        _nameLabel = [NSTextField labelWithString:@""];
        _nameLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
        _nameLabel.textColor = ThemeTextPrimary();
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _detailLabel = [NSTextField labelWithString:@""];
        _detailLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        _detailLabel.textColor = ThemeTextTertiary();
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _altitudeLabel = [NSTextField labelWithString:@""];
        _altitudeLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        _altitudeLabel.textColor = ThemeTextSecondary();
        _altitudeLabel.alignment = NSTextAlignmentRight;
        _altitudeLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _starButton = [NSButton buttonWithTitle:@"★" target:nil action:nil];
        _starButton.bordered = NO;
        _starButton.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        _starButton.contentTintColor = ThemeWarning();
        _starButton.translatesAutoresizingMaskIntoConstraints = NO;
        _starButton.hidden = YES;

        [self addSubview:_dot];
        [self addSubview:_nameLabel];
        [self addSubview:_detailLabel];
        [self addSubview:_altitudeLabel];
        [self addSubview:_starButton];

        [NSLayoutConstraint activateConstraints:@[
            [_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_dot.widthAnchor constraintEqualToConstant:7],
            [_dot.heightAnchor constraintEqualToConstant:7],
            [_dot.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:9],
            [_nameLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_altitudeLabel.leadingAnchor
                                                                constant:-8],

            [_detailLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
            [_detailLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:1],
            [_detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                                   constant:-12],

            [_altitudeLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_altitudeLabel.centerYAnchor constraintEqualToAnchor:_nameLabel.centerYAnchor],

            [_starButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_starButton.centerYAnchor constraintEqualToAnchor:_detailLabel.centerYAnchor],
            [_starButton.widthAnchor constraintEqualToConstant:14],
            [_starButton.heightAnchor constraintEqualToConstant:14],
        ]];
    }
    return self;
}

@end

// MARK: - Controller

@interface AppController () <CaelusGlobeViewDelegate, NSTableViewDataSource, NSTableViewDelegate,
                              NSSearchFieldDelegate, NSWindowDelegate>
- (void)reloadSearch;
- (void)restoreSelectionInTable;
- (void)updateInspector;
- (void)updateStatus;
- (void)updateClock;
- (void)refreshVisibleRows;
- (void)refreshSelectedLive;
- (void)refreshTrackIfStale;
- (void)refreshSelectionForIndex:(NSInteger)index rebuildTrack:(BOOL)rebuildTrack fly:(BOOL)fly;
- (void)flyToIndex:(NSInteger)index;
- (void)applyResult:(const caelus::CatalogService::LoadResult&)result;
- (BOOL)writeSnapshotTo:(NSString*)path;
- (void)redrawTracks;
- (void)loadPreferences;
- (void)savePreferences;
- (void)buildGlobeLayers;
- (void)startFromCache;
- (void)applyObserverSite:(const caelus::ObserverSite&)site;
- (void)toggleFavoriteID:(int)satelliteID;
@end

@implementation AppController {
    // Model.
    caelus::SatelliteCatalog _catalog;
    caelus::PropagationEngine _engine;
    caelus::SnapshotBuffer _buffer;
    std::unique_ptr<caelus::URLSessionHttpClient> _http;
    std::unique_ptr<caelus::CelesTrakClient> _celestrak;
    std::unique_ptr<caelus::CatalogService> _service;

    std::set<int> _favorites;
    std::set<caelus::SatelliteGroup> _activeGroups;
    std::vector<size_t> _searchResults;
    std::optional<caelus::SatelliteState> _selectedState;
    std::vector<caelus::TrackSample> _trackSamples;
    std::vector<caelus::PassEvent> _passes;
    caelus::ObserverSite _observer;
    caelus::DataProvenance _provenance;
    std::string _query;

    NSInteger _selectedIndex;
    NSInteger _hoveredIndex;
    CaelusLoadState _loadState;
    BOOL _isRefreshing;
    BOOL _isLoadingPasses;
    BOOL _showOrbit;
    BOOL _showGround;
    BOOL _showObserver;
    BOOL _favoritesOnly;
    BOOL _inspectorVisible;
    BOOL _didCaptureSnapshot;
    BOOL _tickInFlight;
    BOOL _liveInFlight;
    BOOL _trackInFlight;
    BOOL _updatingTable;
    double _pointSize;
    double _snapshotDuration;
    double _lastTrackRefresh;
    int _propagationFailures;
    NSString* _statusMessage;

    dispatch_queue_t _work;
    dispatch_queue_t _network;
    NSTimer* _clockTimer;

    // Views.
    NSWindow* _window;
    NSView* _content;
    NSView* _sidebar;
    CaelusGlobeView* _globe;
    NSView* _inspector;
    NSView* _statusBar;
    NSLayoutConstraint* _inspectorWidth;
    NSSearchField* _searchField;
    NSTableView* _table;
    NSScrollView* _tableScroll;
    NSStackView* _chipRows;
    NSMutableArray<NSButton*>* _chips;
    NSButton* _favoritesButton;
    NSTextField* _resultsHeader;
    NSTextField* _emptyLabel;
    NSTextField* _hoverLabel;

    // Inspector.
    NSTextField* _insTitle;
    NSTextField* _insSubtitle;
    NSButton* _insFavorite;
    CaelusPill* _pillClass;
    CaelusPill* _pillSun;
    CaelusPill* _pillHorizon;
    NSTextField* _valueAltitude;
    NSTextField* _valueVelocity;
    NSTextField* _valueLatitude;
    NSTextField* _valueLongitude;
    NSTextField* _valueRange;
    NSTextField* _valueElevation;
    NSTextField* _valueAzimuth;
    NSTextField* _valueNextRise;
    NSTextField* _valueInclination;
    NSTextField* _valuePeriod;
    NSTextField* _valueApogee;
    NSTextField* _valuePerigee;
    NSTextField* _valueRaan;
    NSTextField* _valueEccentricity;
    NSTextField* _valueEpoch;
    NSTextField* _passesLabel;
    NSTextField* _inspectorStatus;

    // Status bar.
    NSView* _sourceDot;
    NSTextField* _sourceLabel;
    NSTextField* _countLabel;
    NSTextField* _sgp4Label;
    NSTextField* _clockLabel;
    NSTextField* _siteLabel;

    // Settings.
    NSWindow* _settingsWindow;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _work = dispatch_queue_create("com.lucatufariello.caelus.work", DISPATCH_QUEUE_SERIAL);
        _network = dispatch_queue_create("com.lucatufariello.caelus.network",
                                         DISPATCH_QUEUE_CONCURRENT);

        _http = std::make_unique<caelus::URLSessionHttpClient>();
        _celestrak = std::make_unique<caelus::CelesTrakClient>(*_http);
        _service = std::make_unique<caelus::CatalogService>(
            caelus::CacheStore::applicationDefault(), *_celestrak);

        _observer = caelus::ObserverSite::rome();
        _provenance = caelus::DataProvenance::none;
        _selectedIndex = -1;
        _hoveredIndex = -1;
        _loadState = CaelusLoadStateIdle;
        _showOrbit = YES;
        _showGround = YES;
        _showObserver = YES;
        _pointSize = 1.0;
        _lastTrackRefresh = 0;
        _activeGroups = {caelus::SatelliteGroup::stations, caelus::SatelliteGroup::starlink,
                         caelus::SatelliteGroup::navigation, caelus::SatelliteGroup::weather,
                         caelus::SatelliteGroup::science, caelus::SatelliteGroup::other};
    }
    return self;
}

// MARK: - Window installation

- (void)installInWindow:(NSWindow*)window {
    _window = window;
    window.delegate = self;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.backgroundColor = ThemeBackground();
    window.title = @"Caelus";
    window.minSize = NSMakeSize(980, 640);

    _content = [[NSView alloc] initWithFrame:window.contentLayoutRect];
    _content.wantsLayer = YES;
    _content.layer.backgroundColor = ThemeBackground().CGColor;
    window.contentView = _content;

    [self buildSidebar];
    [self buildGlobe];
    [self buildInspector];
    [self buildStatusBar];
    [self layoutChrome];
    [self loadPreferences];
    [self start];

    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                   target:self
                                                 selector:@selector(clockFired:)
                                                 userInfo:nil
                                                  repeats:YES];
    _clockTimer.tolerance = 0.1;
}

- (void)buildGlobe {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _globe = [[CaelusGlobeView alloc] initWithFrame:NSZeroRect device:device];
    _globe.translatesAutoresizingMaskIntoConstraints = NO;
    _globe.globeDelegate = self;
    [_globe attachSnapshotBuffer:&_buffer];
    [_globe setObserverSite:_observer];
    [_content addSubview:_globe];

    _hoverLabel = [NSTextField labelWithString:@""];
    _hoverLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    _hoverLabel.textColor = ThemeTextPrimary();
    _hoverLabel.wantsLayer = YES;
    _hoverLabel.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.72].CGColor;
    _hoverLabel.layer.cornerRadius = 6;
    _hoverLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hoverLabel.hidden = YES;
    [_content addSubview:_hoverLabel];
}

- (NSTextField*)labelFont:(NSFont*)font color:(NSColor*)color {
    NSTextField* label = [NSTextField labelWithString:@""];
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)buildSidebar {
    _sidebar = [[NSView alloc] init];
    _sidebar.wantsLayer = YES;
    _sidebar.layer.backgroundColor = ThemeSurface().CGColor;
    _sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addSubview:_sidebar];

    NSTextField* brand = [NSTextField labelWithString:@"CAELUS"];
    brand.font = [NSFont systemFontOfSize:15 weight:NSFontWeightBold];
    brand.textColor = ThemeTextPrimary();
    brand.attributedStringValue = [[NSAttributedString alloc]
        initWithString:@"CAELUS"
            attributes:@{
                NSFontAttributeName : [NSFont systemFontOfSize:15 weight:NSFontWeightBold],
                NSForegroundColorAttributeName : ThemeTextPrimary(),
                NSKernAttributeName : @2.6,
            }];
    brand.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:brand];

    NSTextField* tagline = [self labelFont:[NSFont systemFontOfSize:10.5]
                                     color:ThemeTextTertiary()];
    tagline.stringValue = @"Orbital tracking";
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:tagline];

    _searchField = [[NSSearchField alloc] init];
    _searchField.placeholderString = @"Search satellites";
    _searchField.delegate = self;
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:_searchField];

    _chipRows = [[NSStackView alloc] init];
    _chipRows.orientation = NSUserInterfaceLayoutOrientationVertical;
    _chipRows.alignment = NSLayoutAttributeLeading;
    _chipRows.spacing = 5;
    _chipRows.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:_chipRows];

    _chips = [NSMutableArray array];
    NSMutableArray<NSStackView*>* rows = [NSMutableArray array];
    for (int index = 0; index < 6; ++index) {
        if (index % 2 == 0) {
            NSStackView* row = [[NSStackView alloc] init];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.spacing = 5;
            [rows addObject:row];
        }
        caelus::SatelliteGroup group = caelus::allGroups()[static_cast<size_t>(index)];
        NSButton* chip = [NSButton buttonWithTitle:StdString(caelus::title(group))
                                            target:self
                                            action:@selector(chipTapped:)];
        chip.buttonType = NSButtonTypeToggle;
        chip.bezelStyle = NSBezelStyleRounded;
        chip.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
        chip.tag = index;
        chip.state = NSControlStateValueOn;
        chip.contentTintColor = GroupColor(group);
        [_chips addObject:chip];
        [rows.lastObject addArrangedSubview:chip];
    }
    for (NSStackView* row in rows) [_chipRows addArrangedSubview:row];

    _resultsHeader = [self labelFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]
                               color:ThemeTextTertiary()];
    _resultsHeader.stringValue = @"RESULTS";
    _resultsHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:_resultsHeader];

    _favoritesButton = [NSButton buttonWithTitle:@"☆ Favourites"
                                          target:self
                                          action:@selector(toggleFavoritesOnly:)];
    _favoritesButton.bordered = NO;
    _favoritesButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    _favoritesButton.contentTintColor = ThemeTextSecondary();
    _favoritesButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:_favoritesButton];

    _table = [[NSTableView alloc] init];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = 44;
    _table.intercellSpacing = NSMakeSize(0, 0);
    _table.backgroundColor = [NSColor clearColor];
    _table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsMultipleSelection = NO;
    _table.focusRingType = NSFocusRingTypeNone;

    _tableScroll = [[NSScrollView alloc] init];
    _tableScroll.documentView = _table;
    _tableScroll.hasVerticalScroller = YES;
    _tableScroll.drawsBackground = NO;
    _tableScroll.borderType = NSNoBorder;
    _tableScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:_tableScroll];

    _emptyLabel = [self labelFont:[NSFont systemFontOfSize:11.5] color:ThemeTextTertiary()];
    _emptyLabel.stringValue = @"Nothing matches this filter.";
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.hidden = YES;
    [_sidebar addSubview:_emptyLabel];

    NSButton* refresh = [NSButton buttonWithTitle:@"Refresh"
                                           target:self
                                           action:@selector(refreshCatalog:)];
    refresh.bezelStyle = NSBezelStyleRounded;
    refresh.controlSize = NSControlSizeSmall;
    refresh.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];

    NSButton* settings = [NSButton buttonWithTitle:@"Settings"
                                            target:self
                                            action:@selector(showSettings:)];
    settings.bezelStyle = NSBezelStyleRounded;
    settings.controlSize = NSControlSizeSmall;
    settings.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];

    NSStackView* footer = [NSStackView stackViewWithViews:@[refresh, settings]];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.spacing = 6;
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar addSubview:footer];

    [NSLayoutConstraint activateConstraints:@[
        [brand.leadingAnchor constraintEqualToAnchor:_sidebar.leadingAnchor constant:16],
        [brand.topAnchor constraintEqualToAnchor:_sidebar.topAnchor constant:16],
        [tagline.leadingAnchor constraintEqualToAnchor:brand.leadingAnchor],
        [tagline.topAnchor constraintEqualToAnchor:brand.bottomAnchor constant:0],

        [_searchField.leadingAnchor constraintEqualToAnchor:_sidebar.leadingAnchor constant:14],
        [_searchField.trailingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor constant:-14],
        [_searchField.topAnchor constraintEqualToAnchor:tagline.bottomAnchor constant:12],

        [_chipRows.leadingAnchor constraintEqualToAnchor:_searchField.leadingAnchor],
        [_chipRows.trailingAnchor constraintLessThanOrEqualToAnchor:_sidebar.trailingAnchor constant:-14],
        [_chipRows.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:10],

        [_resultsHeader.leadingAnchor constraintEqualToAnchor:_searchField.leadingAnchor],
        [_resultsHeader.topAnchor constraintEqualToAnchor:_chipRows.bottomAnchor constant:14],
        [_favoritesButton.trailingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor constant:-14],
        [_favoritesButton.centerYAnchor constraintEqualToAnchor:_resultsHeader.centerYAnchor],

        [_tableScroll.leadingAnchor constraintEqualToAnchor:_sidebar.leadingAnchor],
        [_tableScroll.trailingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [_tableScroll.topAnchor constraintEqualToAnchor:_resultsHeader.bottomAnchor constant:6],
        [_tableScroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-8],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:_tableScroll.centerXAnchor],
        [_emptyLabel.topAnchor constraintEqualToAnchor:_tableScroll.topAnchor constant:36],
        [_emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:_tableScroll.widthAnchor constant:-24],

        [footer.leadingAnchor constraintEqualToAnchor:_sidebar.leadingAnchor constant:14],
        [footer.bottomAnchor constraintEqualToAnchor:_sidebar.bottomAnchor constant:-12],
    ]];
}

- (NSTextField*)addRowToStack:(NSStackView*)stack title:(NSString*)title {
    NSStackView* row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.distribution = NSStackViewDistributionFill;
    row.alignment = NSLayoutAttributeCenterY;

    NSTextField* key = [self labelFont:[NSFont systemFontOfSize:11] color:ThemeTextSecondary()];
    key.stringValue = title;
    [key setContentHuggingPriority:251 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSTextField* value = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:11
                                                                        weight:NSFontWeightMedium]
                                   color:ThemeTextPrimary()];
    value.alignment = NSTextAlignmentRight;
    value.stringValue = @"—";
    [value setContentHuggingPriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [value setContentCompressionResistancePriority:749
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];

    [row addArrangedSubview:key];
    [row addArrangedSubview:value];
    [stack addArrangedSubview:row];
    return value;
}

- (NSTextField*)sectionHeader:(NSString*)text {
    NSTextField* label = [self labelFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]
                                   color:ThemeTextTertiary()];
    label.stringValue = text;
    return label;
}

- (void)buildInspector {
    _inspector = [[NSView alloc] init];
    _inspector.wantsLayer = YES;
    _inspector.layer.backgroundColor = ThemeSurface().CGColor;
    _inspector.translatesAutoresizingMaskIntoConstraints = NO;
    _inspector.hidden = YES;
    [_content addSubview:_inspector];

    NSStackView* stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeWidth;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField* title = [self labelFont:[NSFont systemFontOfSize:17 weight:NSFontWeightSemibold]
                                   color:ThemeTextPrimary()];
    title.maximumNumberOfLines = 2;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    _insTitle = title;

    _insSubtitle = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:10.5
                                                                   weight:NSFontWeightRegular]
                              color:ThemeTextTertiary()];

    _insFavorite = [NSButton buttonWithTitle:@"☆"
                                      target:self
                                      action:@selector(toggleFavoriteSelection:)];
    _insFavorite.bordered = NO;
    _insFavorite.font = [NSFont systemFontOfSize:16];
    _insFavorite.contentTintColor = ThemeWarning();

    NSButton* close = [NSButton buttonWithTitle:@"✕" target:self action:@selector(clearSelection:)];
    close.bordered = NO;
    close.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    close.contentTintColor = ThemeTextSecondary();

    NSStackView* headerRow = [[NSStackView alloc] init];
    headerRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headerRow.spacing = 6;
    headerRow.alignment = NSLayoutAttributeTop;
    [headerRow addArrangedSubview:title];
    [headerRow addArrangedSubview:_insFavorite];
    [headerRow addArrangedSubview:close];
    [title setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:_insSubtitle];

    NSStackView* pills = [[NSStackView alloc] init];
    pills.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pills.spacing = 6;
    _pillClass = [[CaelusPill alloc] initWithFrame:NSZeroRect];
    _pillSun = [[CaelusPill alloc] initWithFrame:NSZeroRect];
    _pillHorizon = [[CaelusPill alloc] initWithFrame:NSZeroRect];
    [pills addArrangedSubview:_pillClass];
    [pills addArrangedSubview:_pillSun];
    [pills addArrangedSubview:_pillHorizon];
    [stack addArrangedSubview:pills];

    [stack addArrangedSubview:[self sectionHeader:@"LIVE"]];
    _valueAltitude = [self addRowToStack:stack title:@"Altitude"];
    _valueVelocity = [self addRowToStack:stack title:@"Velocity"];
    _valueLatitude = [self addRowToStack:stack title:@"Latitude"];
    _valueLongitude = [self addRowToStack:stack title:@"Longitude"];

    [stack addArrangedSubview:[self sectionHeader:@"FROM STATION"]];
    _valueRange = [self addRowToStack:stack title:@"Range"];
    _valueElevation = [self addRowToStack:stack title:@"Elevation"];
    _valueAzimuth = [self addRowToStack:stack title:@"Azimuth"];
    _valueNextRise = [self addRowToStack:stack title:@"Next rise"];

    [stack addArrangedSubview:[self sectionHeader:@"ORBITAL ELEMENTS"]];
    _valueInclination = [self addRowToStack:stack title:@"Inclination"];
    _valuePeriod = [self addRowToStack:stack title:@"Period"];
    _valueApogee = [self addRowToStack:stack title:@"Apogee"];
    _valuePerigee = [self addRowToStack:stack title:@"Perigee"];
    _valueRaan = [self addRowToStack:stack title:@"RAAN"];
    _valueEccentricity = [self addRowToStack:stack title:@"Eccentricity"];
    _valueEpoch = [self addRowToStack:stack title:@"Element age"];

    [stack addArrangedSubview:[self sectionHeader:@"NEXT PASSES"]];
    _passesLabel = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:10.5
                                                                 weight:NSFontWeightRegular]
                              color:ThemeTextSecondary()];
    _passesLabel.maximumNumberOfLines = 0;
    _passesLabel.stringValue = @"—";
    [stack addArrangedSubview:_passesLabel];

    _inspectorStatus = [self labelFont:[NSFont systemFontOfSize:10] color:ThemeTextTertiary()];
    _inspectorStatus.stringValue = @"Select a satellite on the globe.";
    [stack addArrangedSubview:_inspectorStatus];

    [_inspector addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:_inspector.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:_inspector.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:_inspector.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:_inspector.bottomAnchor],
    ]];
}

- (void)buildStatusBar {
    _statusBar = [[NSView alloc] init];
    _statusBar.wantsLayer = YES;
    _statusBar.layer.backgroundColor = ThemeRaised().CGColor;
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    [_content addSubview:_statusBar];

    _sourceDot = [[NSView alloc] init];
    _sourceDot.wantsLayer = YES;
    _sourceDot.layer.cornerRadius = 3;
    _sourceDot.layer.backgroundColor = ThemeTextTertiary().CGColor;
    _sourceDot.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_sourceDot];

    _sourceLabel = [self labelFont:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold]
                             color:ThemeTextSecondary()];
    _sourceLabel.stringValue = @"OFFLINE";
    _sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_sourceLabel];

    _countLabel = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:9.5
                                                                 weight:NSFontWeightRegular]
                            color:ThemeTextTertiary()];
    _countLabel.stringValue = @"0 objects";
    _countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_countLabel];

    _sgp4Label = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:9.5
                                                                weight:NSFontWeightRegular]
                           color:ThemeTextTertiary()];
    _sgp4Label.stringValue = @"SGP4 —";
    _sgp4Label.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_sgp4Label];

    _clockLabel = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:9.5
                                                                 weight:NSFontWeightMedium]
                            color:ThemeTextSecondary()];
    _clockLabel.stringValue = @"--:--:-- UTC";
    _clockLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_clockLabel];

    _siteLabel = [self labelFont:[NSFont monospacedDigitSystemFontOfSize:9.5
                                                                weight:NSFontWeightRegular]
                           color:ThemeTextTertiary()];
    _siteLabel.stringValue = StdString(_observer.name);
    _siteLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusBar addSubview:_siteLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_statusBar.heightAnchor constraintEqualToConstant:26],
        [_sourceDot.leadingAnchor constraintEqualToAnchor:_statusBar.leadingAnchor constant:14],
        [_sourceDot.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
        [_sourceDot.widthAnchor constraintEqualToConstant:6],
        [_sourceDot.heightAnchor constraintEqualToConstant:6],
        [_sourceLabel.leadingAnchor constraintEqualToAnchor:_sourceDot.trailingAnchor constant:6],
        [_sourceLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
        [_countLabel.leadingAnchor constraintEqualToAnchor:_sourceLabel.trailingAnchor constant:12],
        [_countLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],

        [_siteLabel.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor constant:-14],
        [_siteLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
        [_clockLabel.trailingAnchor constraintEqualToAnchor:_siteLabel.leadingAnchor constant:-14],
        [_clockLabel.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
        [_sgp4Label.trailingAnchor constraintEqualToAnchor:_clockLabel.leadingAnchor constant:-16],
        [_sgp4Label.centerYAnchor constraintEqualToAnchor:_statusBar.centerYAnchor],
    ]];
}

- (void)layoutChrome {
    _sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    _globe.translatesAutoresizingMaskIntoConstraints = NO;
    _inspector.translatesAutoresizingMaskIntoConstraints = NO;

    _inspectorWidth = [_inspector.widthAnchor constraintEqualToConstant:0];

    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor],
        [_sidebar.topAnchor constraintEqualToAnchor:_content.topAnchor],
        [_sidebar.widthAnchor constraintEqualToConstant:316],
        [_sidebar.bottomAnchor constraintEqualToAnchor:_statusBar.topAnchor],

        [_statusBar.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor],
        [_statusBar.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor],
        [_statusBar.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor],

        [_globe.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [_globe.topAnchor constraintEqualToAnchor:_content.topAnchor],
        [_globe.bottomAnchor constraintEqualToAnchor:_statusBar.topAnchor],
        [_globe.trailingAnchor constraintEqualToAnchor:_inspector.leadingAnchor],

        [_inspector.topAnchor constraintEqualToAnchor:_content.topAnchor],
        [_inspector.bottomAnchor constraintEqualToAnchor:_statusBar.topAnchor],
        [_inspector.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor],
        _inspectorWidth,

        [_hoverLabel.leadingAnchor constraintEqualToAnchor:_globe.leadingAnchor constant:14],
        [_hoverLabel.topAnchor constraintEqualToAnchor:_globe.topAnchor constant:14],
    ]];
}

- (void)setInspectorVisible:(BOOL)visible {
    if (visible == _inspectorVisible) return;
    _inspectorVisible = visible;
    _inspector.hidden = !visible;
    _inspectorWidth.constant = visible ? 348 : 0;
    if (!visible) {
        _insTitle.stringValue = @"";
        _inspectorStatus.stringValue = @"Select a satellite on the globe.";
    }
}

// MARK: - Lifecycle

- (void)start {
    StartupMark(@"model created");
    [self buildGlobeLayers];
    [self startFromCache];
}

- (void)buildGlobeLayers {
    [_globe rebuildLayers:_catalog.renderIndices];
    for (caelus::SatelliteGroup group : caelus::allGroups()) {
        [_globe setGroup:group visible:_activeGroups.count(group) > 0];
    }
    [_globe setObserverVisible:_showObserver];
    [_globe setPointRadius:2.2 * _pointSize];
    [_globe setObserverSite:_observer];
}

- (void)startFromCache {
    _loadState = CaelusLoadStateLoading;
    [self updateStatus];
    __weak AppController* weakSelf = self;
    dispatch_async(_network, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        std::optional<caelus::CatalogService::LoadResult> cached =
            strongSelf->_service->loadFromCache();
        dispatch_async(dispatch_get_main_queue(), ^{
            AppController* self2 = weakSelf;
            if (self2 == nil) return;
            if (cached) {
                NSLog(@"Caelus startup: cache read (%zu objects)", cached->catalog.count());
                [self2 applyResult:*cached];
            }
            [self2 refreshCatalog:nil];
        });
    });
}

- (void)refreshCatalog:(id)sender {
    if (_isRefreshing || _service == nullptr) return;
    _isRefreshing = YES;
    _statusMessage = nil;
    [self updateStatus];

    __weak AppController* weakSelf = self;
    dispatch_async(_network, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        caelus::CatalogService::LoadResult result = strongSelf->_service->refresh(false);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppController* self2 = weakSelf;
            if (self2 == nil) return;
            self2->_isRefreshing = NO;
            [self2 applyResult:result];
        });
    });
}

- (void)applyResult:(const caelus::CatalogService::LoadResult&)result {
    const bool isFirstLoad = _catalog.count() == 0;
    _catalog = result.catalog;
    _provenance = result.provenance;
    _statusMessage = result.isDegraded ? @"Some sources were unavailable — showing cached data."
                                       : nil;

    if (_catalog.count() > 0) {
        _loadState = CaelusLoadStateReady;
    } else if (isFirstLoad) {
        _loadState = CaelusLoadStateFailed;
        _statusMessage = @"No satellite data could be loaded. Check your connection and retry.";
    }

    if (_catalog.count() == 0) {
        [self updateStatus];
        [self reloadSearch];
        return;
    }

    if (isFirstLoad) {
        StartupMark([NSString stringWithFormat:@"first catalog applied (%zu objects)",
                                               _catalog.count()]);
        [self buildGlobeLayers];
    }

    const std::vector<caelus::SatelliteRecord> records = _catalog.records;
    __weak AppController* weakSelf = self;
    dispatch_async(_work, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf->_engine.load(records);
        if (isFirstLoad) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf clockFired:nil];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                AppController* self2 = weakSelf;
                if (self2 == nil) return;
                if (self2->_selectedIndex >= 0 &&
                    (size_t)self2->_selectedIndex < self2->_catalog.count()) {
                    [self2 refreshSelectionForIndex:self2->_selectedIndex rebuildTrack:YES fly:NO];
                }
            });
        }
    });

    [self reloadSearch];
    if (_selectedIndex >= 0 && (size_t)_selectedIndex >= _catalog.count()) {
        [self clearSelection:nil];
    }
    [self updateStatus];
}

// MARK: - Tick

- (void)clockFired:(NSTimer*)timer {
    [self updateClock];
    if (_tickInFlight) return;
    _tickInFlight = YES;

    __weak AppController* weakSelf = self;
    dispatch_async(_work, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        const caelus::Date now = caelus::sky::nowDate();
        caelus::SatelliteSnapshot snapshot = strongSelf->_engine.tick(now);
        strongSelf->_buffer.push(snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppController* self2 = weakSelf;
            if (self2 == nil) return;
            self2->_tickInFlight = NO;
            self2->_snapshotDuration = snapshot.duration;
            self2->_propagationFailures = snapshot.failures;
            [self2 updateStatus];
            [self2 refreshVisibleRows];
            [self2 refreshSelectedLive];
            [self2 refreshTrackIfStale];
        });
    });
}

- (void)refreshSelectedLive {
    if (_selectedIndex < 0 || (size_t)_selectedIndex >= _catalog.count()) return;
    if (_liveInFlight) return;
    _liveInFlight = YES;
    const NSInteger index = _selectedIndex;
    const caelus::ObserverSite site = _observer;
    const caelus::Date now = caelus::sky::nowDate();

    __weak AppController* weakSelf = self;
    dispatch_async(_work, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        std::optional<caelus::SatelliteState> state =
            strongSelf->_engine.state((size_t)index, now, &site);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppController* self2 = weakSelf;
            if (self2 == nil) return;
            self2->_liveInFlight = NO;
            if (self2->_selectedIndex != index) return;
            if (state) {
                self2->_selectedState = state;
                [self2->_globe setSelectionPosition:state->position
                                              valid:YES
                                              color:GroupColor(strongSelf->_catalog.records[(size_t)index].renderGroup())];
            }
            [self2 updateInspector];
        });
    });
}

// MARK: - Selection

- (CaelusGlobeView*)globeView {
    return _globe;
}

- (NSInteger)selectedIndex {
    return _selectedIndex;
}

- (void)selectIndex:(NSInteger)index {
    if (index == _selectedIndex) return;
    if (index < 0 || (size_t)index >= _catalog.count()) {
        [self clearSelection:nil];
        return;
    }
    _selectedIndex = index;
    _selectedState = std::nullopt;
    _trackSamples.clear();
    _passes.clear();
    _isLoadingPasses = YES;
    [_globe clearTrack];
    [self setInspectorVisible:YES];
    [self refreshSelectionForIndex:index rebuildTrack:YES fly:YES];
    [self updateInspector];
    [self updateStatus];
}

- (void)refreshSelectionForIndex:(NSInteger)index rebuildTrack:(BOOL)rebuildTrack fly:(BOOL)fly {
    if (index < 0 || (size_t)index >= _catalog.count()) return;
    const NSInteger expected = index;
    const caelus::ObserverSite site = _observer;
    const caelus::Date now = caelus::sky::nowDate();

    if (fly) [self flyToIndex:index];

    __weak AppController* weakSelf = self;
    dispatch_async(_work, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        std::optional<caelus::SatelliteState> state =
            strongSelf->_engine.state((size_t)index, now, &site);

        const caelus::SatelliteRecord record = strongSelf->_catalog.records[(size_t)index];
        const double period = record.periodMinutes() > 1 ? record.periodMinutes() : 95.0;
        const double halfSpan = std::min(720.0, std::max(40.0, period / 2.0));
        const double step = std::max(10.0, (2.0 * halfSpan * 60.0) / 260.0);
        std::vector<caelus::TrackSample> samples;
        if (rebuildTrack) {
            samples = strongSelf->_engine.trackSamples((size_t)index, caelus::sky::nowDate(),
                                                       halfSpan, step);
        }
        const std::vector<caelus::PassEvent> events =
            strongSelf->_engine.passes((size_t)index, site, caelus::sky::nowDate(), 24, 10, 8);

        dispatch_async(dispatch_get_main_queue(), ^{
            AppController* self2 = weakSelf;
            if (self2 == nil || self2->_selectedIndex != expected) return;
            if (state) {
                self2->_selectedState = state;
                [self2->_globe setSelectionPosition:state->position
                                              valid:YES
                                              color:GroupColor(record.renderGroup())];
            }
            if (rebuildTrack) {
                self2->_trackSamples = samples;
                self2->_lastTrackRefresh = caelus::sky::nowDate();
                [self2->_globe updateTrackSamples:samples
                                            color:GroupColor(record.renderGroup())
                                        showOrbit:self2->_showOrbit
                                       showGround:self2->_showGround];
            }
            self2->_passes = events;
            self2->_isLoadingPasses = NO;
            [self2 updateInspector];
            [self2 updateStatus];
        });
    });
}

- (void)flyToIndex:(NSInteger)index {
    if (index < 0 || (size_t)index >= _catalog.count()) return;
    const caelus::SatelliteRecord& record = _catalog.records[(size_t)index];
    const double altitude = std::max(0.0, record.perigeeKm());
    const float distance = (float)std::min(6.0, std::max(1.9, 1.0 + altitude / caelus::GeoMath::earthRadiusKm() + 1.5));
    if (_selectedState) {
        [_globe focusLatitude:_selectedState->latitude
                    longitude:_selectedState->longitude
                     distance:distance];
    } else {
        const NSInteger expected = index;
        const caelus::ObserverSite site = _observer;
        __weak AppController* weakSelf = self;
        dispatch_async(_work, ^{
            AppController* strongSelf = weakSelf;
            if (strongSelf == nil) return;
            std::optional<caelus::SatelliteState> state =
                strongSelf->_engine.state((size_t)index, caelus::sky::nowDate(), &site);
            if (!state) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                AppController* self2 = weakSelf;
                if (self2 != nil && self2->_selectedIndex == expected) {
                    [self2->_globe focusLatitude:state->latitude
                                       longitude:state->longitude
                                        distance:distance];
                }
            });
        });
    }
}

- (void)refreshTrackIfStale {
    if (_selectedIndex < 0 || _trackInFlight) return;
    if (caelus::sky::nowDate() - _lastTrackRefresh <= 5.0) return;
    _trackInFlight = YES;
    const NSInteger index = _selectedIndex;
    const std::string name = _catalog.records[(size_t)index].name;
    const caelus::SatelliteGroup group = _catalog.records[(size_t)index].renderGroup();
    const caelus::SatelliteRecord record = _catalog.records[(size_t)index];
    const double period = record.periodMinutes() > 1 ? record.periodMinutes() : 95.0;
    const double halfSpan = std::min(720.0, std::max(40.0, period / 2.0));
    const double step = std::max(10.0, (2.0 * halfSpan * 60.0) / 260.0);

    __weak AppController* weakSelf = self;
    dispatch_async(_work, ^{
        AppController* strongSelf = weakSelf;
        if (strongSelf == nil) return;
        std::vector<caelus::TrackSample> samples =
            strongSelf->_engine.trackSamples((size_t)index, caelus::sky::nowDate(), halfSpan, step);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppController* self2 = weakSelf;
            if (self2 == nil) return;
            self2->_trackInFlight = NO;
            if (self2->_selectedIndex != index) return;
            self2->_trackSamples = samples;
            self2->_lastTrackRefresh = caelus::sky::nowDate();
            [self2->_globe updateTrackSamples:samples
                                        color:GroupColor(group)
                                    showOrbit:self2->_showOrbit
                                   showGround:self2->_showGround];
        });
    });
}

- (void)clearSelection:(id)sender {
    if (_selectedIndex == -1 && !_inspectorVisible) return;
    _selectedIndex = -1;
    _selectedState = std::nullopt;
    _trackSamples.clear();
    _passes.clear();
    [_globe clearTrack];
    [_table deselectAll:nil];
    [self setInspectorVisible:NO];
    [self updateStatus];
}

- (BOOL)isFavorite:(int)satelliteID {
    return _favorites.count(satelliteID) > 0;
}

- (NSUInteger)catalogCount {
    return _catalog.count();
}

- (void)toggleFavoriteID:(int)satelliteID {
    if (_favorites.count(satelliteID) > 0) {
        _favorites.erase(satelliteID);
    } else {
        _favorites.insert(satelliteID);
    }
    [self savePreferences];
    [self reloadSearch];
    [self updateInspector];
}

- (void)toggleFavoriteSelection:(id)sender {
    if (_selectedIndex < 0 || (size_t)_selectedIndex >= _catalog.count()) return;
    const int satelliteID = _catalog.records[(size_t)_selectedIndex].id;
    [self toggleFavoriteID:satelliteID];
}

- (void)toggleFavoritesOnly:(id)sender {
    _favoritesOnly = !_favoritesOnly;
    [self reloadSearch];
}

- (void)starClicked:(NSButton*)sender {
    const NSInteger row = sender.tag;
    if (row < 0 || (size_t)row >= _searchResults.size()) return;
    const size_t catalogIndex = _searchResults[(size_t)row];
    [self toggleFavoriteID:_catalog.records[catalogIndex].id];
}

// MARK: - Search and filters

- (void)reloadSearch {
    const std::string query = _searchField.stringValue.UTF8String != nullptr
                                  ? std::string(_searchField.stringValue.UTF8String)
                                  : std::string();
    _query = query;
    _searchResults = _catalog.search(_query, _activeGroups, _favoritesOnly != NO, _favorites);
    _updatingTable = YES;
    [_table reloadData];
    _updatingTable = NO;
    _emptyLabel.hidden = !_searchResults.empty();
    if (_searchResults.empty()) {
        _emptyLabel.hidden = NO;
    }
    [self updateResultsHeader];
    [self restoreSelectionInTable];
}

- (void)updateResultsHeader {
    _resultsHeader.stringValue =
        [NSString stringWithFormat:@"RESULTS · %zu", _searchResults.size()];
    _favoritesButton.title = [NSString stringWithFormat:@"%@ Favourites",
                                                        _favoritesOnly ? @"★" : @"☆"];
    _favoritesButton.contentTintColor = _favoritesOnly ? ThemeWarning() : ThemeTextSecondary();
}

- (void)restoreSelectionInTable {
    if (_selectedIndex < 0) return;
    for (size_t row = 0; row < _searchResults.size(); ++row) {
        if (_searchResults[row] == (size_t)_selectedIndex) {
            _updatingTable = YES;
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            [_table scrollRowToVisible:(NSInteger)row];
            _updatingTable = NO;
            return;
        }
    }
}

- (void)controlTextDidChange:(NSNotification*)notification {
    if (notification.object == _searchField) [self reloadSearch];
}

- (void)chipTapped:(NSButton*)sender {
    if (sender.tag < 0 || sender.tag >= 6) return;
    caelus::SatelliteGroup group = caelus::allGroups()[(size_t)sender.tag];
    const bool enabled = sender.state == NSControlStateValueOn;
    if (enabled) {
        _activeGroups.insert(group);
    } else {
        _activeGroups.erase(group);
    }
    [_globe setGroup:group visible:enabled];
    [self reloadSearch];
    [self updateStatus];
}

- (void)toggleAllGroups:(id)sender {
    const bool enable = _activeGroups.size() != caelus::allGroups().size();
    _activeGroups.clear();
    if (enable) {
        for (caelus::SatelliteGroup group : caelus::allGroups()) _activeGroups.insert(group);
    }
    for (size_t index = 0; index < _chips.count; ++index) {
        caelus::SatelliteGroup group = caelus::allGroups()[index];
        _chips[index].state = enable ? NSControlStateValueOn : NSControlStateValueOff;
        [_globe setGroup:group visible:enable];
    }
    [self reloadSearch];
    [self updateStatus];
}

// MARK: - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return (NSInteger)_searchResults.size();
}

- (NSView*)tableView:(NSTableView*)tableView
   viewForTableColumn:(NSTableColumn*)tableColumn
                  row:(NSInteger)row {
    CaelusRowCell* cell = [tableView makeViewWithIdentifier:@"row" owner:self];
    if (cell == nil) {
        cell = [[CaelusRowCell alloc] initWithFrame:NSMakeRect(0, 0, 300, 44)];
        cell.identifier = @"row";
    }
    if (row < 0 || (size_t)row >= _searchResults.size()) return cell;

    const size_t catalogIndex = _searchResults[(size_t)row];
    const caelus::SatelliteRecord& record = _catalog.records[catalogIndex];
    const caelus::SatelliteGroup group = record.renderGroup();

    cell.nameLabel.stringValue = StdString(record.name);
    cell.detailLabel.stringValue =
        [NSString stringWithFormat:@"%d · %@", record.id, ShortGroupName(group)];
    cell.dot.layer.backgroundColor = GroupColor(group).CGColor;

    const auto snapshot = _buffer.pair().second;
    if (catalogIndex < snapshot.count() && snapshot.valid[catalogIndex]) {
        const double altitude =
            (snapshot.positions[catalogIndex].magnitude() - 1.0) * caelus::GeoMath::earthRadiusKm();
        cell.altitudeLabel.stringValue = [NSString stringWithFormat:@"%.0f km", altitude];
    } else {
        cell.altitudeLabel.stringValue = @"—";
    }

    cell.starButton.tag = row;
    cell.starButton.target = self;
    cell.starButton.action = @selector(starClicked:);
    const bool favorite = _favorites.count(record.id) > 0;
    cell.starButton.hidden = !favorite;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    if (_updatingTable) return;
    const NSInteger row = _table.selectedRow;
    if (row < 0 || (size_t)row >= _searchResults.size()) return;
    [self selectIndex:(NSInteger)_searchResults[(size_t)row]];
}

- (void)refreshVisibleRows {
    if (_table.numberOfRows == 0) return;
    const NSRange visible = [_table rowsInRect:_table.visibleRect];
    if (visible.length == 0) return;
    // Rebuilding just the visible cells keeps a 1 Hz position update cheap even
    // with twenty thousand results behind the scroll view.
    for (NSInteger row = (NSInteger)visible.location;
         row < (NSInteger)(visible.location + visible.length) && row < _table.numberOfRows; ++row) {
        NSView* view = [_table viewAtColumn:0 row:row makeIfNecessary:NO];
        if (view == nil) continue;
        if (![view isKindOfClass:[CaelusRowCell class]]) continue;
        CaelusRowCell* cell = (CaelusRowCell*)view;
        if ((size_t)row >= _searchResults.size()) continue;
        const size_t catalogIndex = _searchResults[(size_t)row];
        const auto snapshot = _buffer.pair().second;
        if (catalogIndex < snapshot.count() && snapshot.valid[catalogIndex]) {
            const double altitude = (snapshot.positions[catalogIndex].magnitude() - 1.0) *
                                    caelus::GeoMath::earthRadiusKm();
            cell.altitudeLabel.stringValue = [NSString stringWithFormat:@"%.0f km", altitude];
        }
    }
}

// MARK: - Inspector

- (void)updateInspector {
    if (_selectedIndex < 0 || (size_t)_selectedIndex >= _catalog.count()) return;
    const caelus::SatelliteRecord& record = _catalog.records[(size_t)_selectedIndex];

    _insTitle.stringValue = StdString(record.name);
    NSString* launch = StdString(record.cosparID());
    _insSubtitle.stringValue = launch.length > 0
        ? [NSString stringWithFormat:@"%d · %@", record.id, launch]
        : [NSString stringWithFormat:@"%d", record.id];
    [_insFavorite setTitle:_favorites.count(record.id) > 0 ? @"★" : @"☆"];

    [_pillClass setText:AltitudeClass(true, record) color:ThemeAccent()];

    if (_selectedState) {
        const caelus::SatelliteState& state = *_selectedState;
        [_pillSun setText:state.sunlit ? @"SUNLIT" : @"ECLIPSE"
                    color:state.sunlit ? ThemeWarning() : ThemeTextSecondary()];
        const bool above = state.elevationFromObserver && *state.elevationFromObserver > 0;
        [_pillHorizon setText:above ? @"ABOVE HORIZON" : @"BELOW HORIZON"
                        color:above ? ThemeSuccess() : ThemeTextSecondary()];

        _valueAltitude.stringValue = [NSString stringWithFormat:@"%.1f km", state.altitudeKm];
        _valueVelocity.stringValue = state.velocityKmS > 0
            ? [NSString stringWithFormat:@"%.2f km/s", state.velocityKmS]
            : @"—";
        _valueLatitude.stringValue = [NSString stringWithFormat:@"%.3f°", state.latitude];
        _valueLongitude.stringValue = [NSString stringWithFormat:@"%.3f°", state.longitude];

        if (state.rangeToObserverKm) {
            _valueRange.stringValue = [NSString stringWithFormat:@"%.0f km", *state.rangeToObserverKm];
        } else {
            _valueRange.stringValue = @"—";
        }
        if (state.elevationFromObserver) {
            _valueElevation.stringValue =
                [NSString stringWithFormat:@"%.1f°", *state.elevationFromObserver];
        } else {
            _valueElevation.stringValue = @"—";
        }
        if (state.azimuthFromObserver) {
            _valueAzimuth.stringValue = [NSString stringWithFormat:@"%.0f° %@",
                                                                   *state.azimuthFromObserver,
                                                                   StdString(caelus::Compass::direction(*state.azimuthFromObserver))];
        } else {
            _valueAzimuth.stringValue = @"—";
        }
    }

    const caelus::Date now = caelus::sky::nowDate();
    if (!_passes.empty()) {
        const caelus::PassEvent& next = _passes.front();
        _valueNextRise.stringValue = [NSString stringWithFormat:@"%@ · %.0f°",
                                                                DayTimeString(next.rise),
                                                                next.maxElevation];
    } else {
        _valueNextRise.stringValue = @"No pass in 24 h";
    }

    _valueInclination.stringValue = [NSString stringWithFormat:@"%.2f°", record.inclinationDeg()];
    _valuePeriod.stringValue = [NSString stringWithFormat:@"%.1f min", record.periodMinutes()];
    _valueApogee.stringValue = [NSString stringWithFormat:@"%.0f km", record.apogeeKm()];
    _valuePerigee.stringValue = [NSString stringWithFormat:@"%.0f km", record.perigeeKm()];
    _valueRaan.stringValue = [NSString stringWithFormat:@"%.2f°", record.raanDeg()];
    _valueEccentricity.stringValue = [NSString stringWithFormat:@"%.5f", record.eccentricity()];
    const double ageDays = record.age(now) / 86400.0;
    _valueEpoch.stringValue = [NSString stringWithFormat:@"%.1f d", ageDays];

    NSMutableString* passText = [NSMutableString string];
    NSInteger shown = 0;
    for (const caelus::PassEvent& pass : _passes) {
        if (pass.rise < now) continue;
        [passText appendFormat:@"%@ → %@   %.0f°  %@%@\n", ClockString(pass.rise),
                               ClockString(pass.set), pass.maxElevation,
                               StdString(pass.riseDirection()),
                               pass.isVisible ? @"  ·  visible" : @""];
        if (++shown >= 5) break;
    }
    _passesLabel.stringValue = passText.length > 0 ? passText : @"No passes in the next 24 hours.";
    _inspectorStatus.stringValue = _isLoadingPasses ? @"Computing passes…" : @"";
}

// MARK: - Status bar

- (NSUInteger)visibleCount {
    NSUInteger total = 0;
    for (caelus::SatelliteGroup group : _activeGroups) {
        const auto found = _catalog.renderIndices.find(group);
        if (found != _catalog.renderIndices.end()) total += found->second.size();
    }
    return total;
}

- (void)updateStatus {
    _sourceLabel.stringValue = ProvenanceTitle(_provenance);
    _sourceLabel.textColor = ProvenanceColor(_provenance);
    _sourceDot.layer.backgroundColor = ProvenanceColor(_provenance).CGColor;
    _countLabel.stringValue = [NSString stringWithFormat:@"%lu objects", (unsigned long)[self visibleCount]];
    _sgp4Label.stringValue = _snapshotDuration > 0
        ? [NSString stringWithFormat:@"SGP4 %.1f ms", _snapshotDuration * 1000.0]
        : @"SGP4 —";
    if (_statusMessage.length > 0) {
        _siteLabel.stringValue = _statusMessage;
        _siteLabel.textColor = ThemeWarning();
    } else {
        _siteLabel.stringValue = [NSString stringWithFormat:@"%@ · %@",
                                                            StdString(_observer.name),
                                                            StdString(_observer.formattedCoordinate())];
        _siteLabel.textColor = ThemeTextTertiary();
    }
}

- (void)updateClock {
    _clockLabel.stringValue = [NSString stringWithFormat:@"%@ UTC", ClockString(caelus::sky::nowDate())];
}

// MARK: - Globe delegate

- (void)globeView:(CaelusGlobeView*)view didSelectIndex:(NSInteger)index {
    if (index >= 0) {
        [self selectIndex:index];
        [self restoreSelectionInTable];
    } else {
        [self clearSelection:nil];
    }
}

- (void)globeView:(CaelusGlobeView*)view didHoverIndex:(NSInteger)index {
    _hoveredIndex = index;
    if (index >= 0 && (size_t)index < _catalog.count()) {
        const caelus::SatelliteRecord& record = _catalog.records[(size_t)index];
        NSString* text = [NSString stringWithFormat:@"  %@  ·  %d  ", StdString(record.name), record.id];
        _hoverLabel.attributedStringValue = [[NSAttributedString alloc]
            initWithString:text
                attributes:@{
                    NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
                    NSForegroundColorAttributeName : ThemeTextPrimary(),
                }];
        _hoverLabel.hidden = NO;
    } else {
        _hoverLabel.hidden = YES;
    }
}

- (void)globeView:(CaelusGlobeView*)view didRequestFocusLatitude:(double)latitude
        longitude:(double)longitude {
    [_globe focusLatitude:latitude longitude:longitude distance:2.4];
}

- (void)globeViewDidRequestReset:(CaelusGlobeView*)view {
    [self resetCamera:nil];
}

// MARK: - Commands

- (void)resetCamera:(id)sender {
    [_globe resetCamera];
}

- (void)toggleOrbitPath:(id)sender {
    _showOrbit = !_showOrbit;
    [self redrawTracks];
    [self savePreferences];
}

- (void)toggleGroundTrack:(id)sender {
    _showGround = !_showGround;
    [self redrawTracks];
    [self savePreferences];
}

- (void)toggleObserver:(id)sender {
    _showObserver = !_showObserver;
    [_globe setObserverVisible:_showObserver];
    [self savePreferences];
}

- (void)redrawTracks {
    if (_selectedIndex < 0 || _trackSamples.empty()) return;
    [_globe updateTrackSamples:_trackSamples
                         color:GroupColor(_catalog.records[(size_t)_selectedIndex].renderGroup())
                     showOrbit:_showOrbit
                    showGround:_showGround];
}

- (void)focusSearch:(id)sender {
    [_window makeFirstResponder:_searchField];
}

// MARK: - Preferences

- (void)loadPreferences {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

    NSArray* storedFavorites = [defaults arrayForKey:@"favorites"];
    _favorites.clear();
    for (id value in storedFavorites) {
        if ([value respondsToSelector:@selector(intValue)]) _favorites.insert([value intValue]);
    }

    NSString* siteName = [defaults stringForKey:@"observerName"];
    if (siteName != nil) {
        _observer.name = siteName.UTF8String ?: "";
        _observer.latitude = [defaults doubleForKey:@"observerLatitude"];
        _observer.longitude = [defaults doubleForKey:@"observerLongitude"];
        _observer.altitudeKm = [defaults doubleForKey:@"observerAltitude"];
    }
    if ([defaults objectForKey:@"showOrbitPath"] != nil) {
        _showOrbit = [defaults boolForKey:@"showOrbitPath"];
    }
    if ([defaults objectForKey:@"showGroundTrack"] != nil) {
        _showGround = [defaults boolForKey:@"showGroundTrack"];
    }
    if ([defaults objectForKey:@"showObserver"] != nil) {
        _showObserver = [defaults boolForKey:@"showObserver"];
    }
    if ([defaults objectForKey:@"pointSize"] != nil) {
        _pointSize = std::min(2.5, std::max(0.5, [defaults doubleForKey:@"pointSize"]));
    }
    _siteLabel.stringValue = StdString(_observer.name);
}

- (void)savePreferences {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray* storedFavorites = [NSMutableArray array];
    for (int satelliteID : _favorites) [storedFavorites addObject:@(satelliteID)];
    [defaults setObject:storedFavorites forKey:@"favorites"];
    [defaults setObject:StdString(_observer.name) forKey:@"observerName"];
    [defaults setDouble:_observer.latitude forKey:@"observerLatitude"];
    [defaults setDouble:_observer.longitude forKey:@"observerLongitude"];
    [defaults setDouble:_observer.altitudeKm forKey:@"observerAltitude"];
    [defaults setBool:_showOrbit forKey:@"showOrbitPath"];
    [defaults setBool:_showGround forKey:@"showGroundTrack"];
    [defaults setBool:_showObserver forKey:@"showObserver"];
    [defaults setDouble:_pointSize forKey:@"pointSize"];
}

// MARK: - Settings sheet

- (void)showSettings:(id)sender {
    if (_settingsWindow != nil) {
        [_window beginSheet:_settingsWindow completionHandler:nil];
        return;
    }

    NSWindow* sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 330)
                                                 styleMask:NSWindowStyleMaskTitled
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    sheet.title = @"Settings";
    sheet.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSView* content = sheet.contentView;
    NSStackView* stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
    ]];

    NSTextField* pointTitle = [self labelFont:[NSFont systemFontOfSize:11] color:ThemeTextSecondary()];
    pointTitle.stringValue = [NSString stringWithFormat:@"Point size · %.1f", _pointSize];
    NSSlider* slider = [NSSlider sliderWithValue:_pointSize
                                       minValue:0.5
                                       maxValue:2.5
                                         target:self
                                         action:@selector(pointSizeChanged:)];
    slider.continuous = YES;
    [slider.widthAnchor constraintEqualToConstant:380].active = YES;
    [stack addArrangedSubview:pointTitle];
    [stack addArrangedSubview:slider];

    NSButton* orbit = [NSButton checkboxWithTitle:@"Show orbit path"
                                           target:self
                                           action:@selector(settingsToggled:)];
    orbit.tag = 1;
    orbit.state = _showOrbit ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton* ground = [NSButton checkboxWithTitle:@"Show ground track"
                                            target:self
                                            action:@selector(settingsToggled:)];
    ground.tag = 2;
    ground.state = _showGround ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton* observer = [NSButton checkboxWithTitle:@"Show ground station"
                                              target:self
                                              action:@selector(settingsToggled:)];
    observer.tag = 3;
    observer.state = _showObserver ? NSControlStateValueOn : NSControlStateValueOff;
    [stack addArrangedSubview:orbit];
    [stack addArrangedSubview:ground];
    [stack addArrangedSubview:observer];

    NSTextField* siteTitle = [self labelFont:[NSFont systemFontOfSize:11] color:ThemeTextSecondary()];
    siteTitle.stringValue = @"Ground station";
    NSPopUpButton* preset = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [preset addItemsWithTitles:@[@"Rome", @"Custom"]];
    preset.tag = 4;
    preset.target = self;
    preset.action = @selector(sitePresetChanged:);
    [stack addArrangedSubview:siteTitle];
    [stack addArrangedSubview:preset];

    NSTextField* lat = [[NSTextField alloc] init];
    lat.placeholderString = @"Latitude";
    lat.stringValue = [NSString stringWithFormat:@"%.4f", _observer.latitude];
    lat.tag = 5;
    [lat.widthAnchor constraintEqualToConstant:120].active = YES;
    NSTextField* lon = [[NSTextField alloc] init];
    lon.placeholderString = @"Longitude";
    lon.stringValue = [NSString stringWithFormat:@"%.4f", _observer.longitude];
    lon.tag = 6;
    [lon.widthAnchor constraintEqualToConstant:120].active = YES;
    NSStackView* fields = [NSStackView stackViewWithViews:@[lat, lon]];
    fields.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fields.spacing = 8;
    [stack addArrangedSubview:fields];

    NSButton* apply = [NSButton buttonWithTitle:@"Apply station"
                                         target:self
                                         action:@selector(applyStation:)];
    apply.bezelStyle = NSBezelStyleRounded;
    [stack addArrangedSubview:apply];

    NSTextField* cacheLabel = [self labelFont:[NSFont systemFontOfSize:10.5]
                                        color:ThemeTextTertiary()];
    const double bytes = _service ? (double)_service->diskUsage() : 0;
    cacheLabel.stringValue = [NSString stringWithFormat:@"Cache · %.1f MB", bytes / (1024.0 * 1024.0)];
    [stack addArrangedSubview:cacheLabel];

    NSButton* clear = [NSButton buttonWithTitle:@"Clear cache"
                                         target:self
                                         action:@selector(clearCache:)];
    clear.bezelStyle = NSBezelStyleRounded;
    NSButton* done = [NSButton buttonWithTitle:@"Done"
                                        target:self
                                        action:@selector(closeSettings:)];
    done.bezelStyle = NSBezelStyleRounded;
    NSStackView* buttons = [NSStackView stackViewWithViews:@[clear, done]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    [stack addArrangedSubview:buttons];

    _settingsWindow = sheet;
    [_window beginSheet:sheet completionHandler:nil];
}

- (void)pointSizeChanged:(NSSlider*)sender {
    _pointSize = sender.doubleValue;
    [_globe setPointRadius:2.2 * _pointSize];
    for (NSView* view in sender.superview.subviews) {
        if ([view isKindOfClass:[NSTextField class]] &&
            [((NSTextField*)view).stringValue hasPrefix:@"Point size"]) {
            ((NSTextField*)view).stringValue =
                [NSString stringWithFormat:@"Point size · %.1f", _pointSize];
        }
    }
    [self savePreferences];
}

- (void)settingsToggled:(NSButton*)sender {
    switch (sender.tag) {
        case 1:
            _showOrbit = sender.state == NSControlStateValueOn;
            [self redrawTracks];
            break;
        case 2:
            _showGround = sender.state == NSControlStateValueOn;
            [self redrawTracks];
            break;
        case 3:
            _showObserver = sender.state == NSControlStateValueOn;
            [_globe setObserverVisible:_showObserver];
            break;
        default: break;
    }
    [self savePreferences];
}

- (void)sitePresetChanged:(NSPopUpButton*)sender {
    if (sender.indexOfSelectedItem == 0) {
        [self applyObserverSite:caelus::ObserverSite::rome()];
    }
}

- (void)applyStation:(id)sender {
    NSWindow* sheet = _settingsWindow;
    NSString* name = @"Custom";
    double latitude = 0;
    double longitude = 0;
    for (NSView* view in sheet.contentView.subviews) {
        (void)view;
    }
    // The fields live inside the sheet's stack; walk to find them by tag.
    NSMutableArray<NSView*>* pending = [NSMutableArray arrayWithObject:sheet.contentView];
    while (pending.count > 0) {
        NSView* view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:[NSTextField class]] &&
            ![(NSTextField*)view isEditable]) {
            // Labels are not editable; skip.
        } else if ([view isKindOfClass:[NSTextField class]]) {
            NSTextField* field = (NSTextField*)view;
            if (field.tag == 5) latitude = field.doubleValue;
            if (field.tag == 6) longitude = field.doubleValue;
        }
        [pending addObjectsFromArray:view.subviews];
    }
    caelus::ObserverSite site;
    site.name = name.UTF8String;
    site.latitude = latitude;
    site.longitude = longitude;
    site.altitudeKm = 0;
    [self applyObserverSite:site];
}

- (void)applyObserverSite:(const caelus::ObserverSite&)site {
    _observer = site;
    [_globe setObserverSite:_observer];
    [self savePreferences];
    [self updateStatus];
    if (_selectedIndex >= 0) {
        [self refreshSelectionForIndex:_selectedIndex rebuildTrack:NO fly:NO];
    }
}

- (void)clearCache:(id)sender {
    if (_service == nullptr) return;
    try {
        _service->clearCache();
        _statusMessage = @"Cache cleared. Refresh to download fresh elements.";
    } catch (...) {
        _statusMessage = @"Could not clear the cache.";
    }
    [self updateStatus];
}

- (void)closeSettings:(id)sender {
    if (_settingsWindow != nil) {
        [_window endSheet:_settingsWindow];
        _settingsWindow = nil;
    }
}

// MARK: - Snapshot capture

- (void)saveImage:(id)sender {
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[ [UTType typeWithIdentifier:@"public.png"] ];
    panel.nameFieldStringValue = @"Caelus.png";
    panel.canCreateDirectories = YES;
    if ([panel runModal] != NSModalResponseOK || panel.URL == nil) return;
    [self writeSnapshotTo:panel.URL.path];
}

- (BOOL)writeSnapshotTo:(NSString*)path {
    NSImage* scene = [_globe snapshotImage];
    if (scene == nil) return NO;

    NSString* sceneDebugPath = NSProcessInfo.processInfo.environment[@"CAELUS_SNAPSHOT_SCENE"];
    if (sceneDebugPath.length > 0) {
        NSData* tiff = scene.TIFFRepresentation;
        NSBitmapImageRep* imageRep = [[NSBitmapImageRep alloc] initWithData:tiff];
        NSData* png = [imageRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (png != nil) [png writeToFile:sceneDebugPath atomically:YES];
    }

    NSView* chrome = _window.contentView;
    NSBitmapImageRep* chromeRep = [chrome bitmapImageRepForCachingDisplayInRect:chrome.bounds];
    if (chromeRep == nil) return NO;

    const BOOL wasHidden = _globe.hidden;
    _globe.hidden = YES;
    CGColorRef background = CGColorRetain(chrome.layer.backgroundColor);
    chrome.layer.backgroundColor = [NSColor clearColor].CGColor;
    [chrome cacheDisplayInRect:chrome.bounds toBitmapImageRep:chromeRep];
    chrome.layer.backgroundColor = background;
    CGColorRelease(background);
    _globe.hidden = wasHidden;

    CGImageRef chromeImage = chromeRep.CGImage;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (chromeImage == NULL || space == NULL) return NO;

    CGContextRef context = CGBitmapContextCreate(NULL, chromeRep.pixelsWide, chromeRep.pixelsHigh, 8,
                                                 chromeRep.bytesPerRow, space,
                                                 static_cast<CGBitmapInfo>(
                                                     kCGImageAlphaPremultipliedLast) |
                                                     kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return NO;

    const CGFloat scale = (CGFloat)chromeRep.pixelsWide / std::max<CGFloat>(1, chrome.bounds.size.width);

    // The globe is a direct child of the content view, and neither is flipped.
    NSRect frame = _globe.frame;
    CGRect sceneRect = CGRectMake(frame.origin.x * scale, frame.origin.y * scale,
                                  frame.size.width * scale, frame.size.height * scale);

    CGImageRef sceneImage = [scene CGImageForProposedRect:NULL context:NULL hints:nil];
    if (sceneImage != NULL) CGContextDrawImage(context, sceneRect, sceneImage);

    CGContextDrawImage(context, CGRectMake(0, 0, chromeRep.pixelsWide, chromeRep.pixelsHigh),
                       chromeImage);

    CGImageRef output = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (output == NULL) return NO;

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:output];
    CGImageRelease(output);
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return png != nil && [png writeToFile:path atomically:YES];
}

- (void)captureSnapshotIfRequested {
    if (_didCaptureSnapshot) return;
    NSString* path = NSProcessInfo.processInfo.environment[@"CAELUS_SNAPSHOT"];
    if (path.length == 0) return;
    _didCaptureSnapshot = YES;

    NSDictionary* environment = NSProcessInfo.processInfo.environment;
    NSString* pose = environment[@"CAELUS_SNAPSHOT_POSE"];
    if (pose.length > 0) {
        NSArray<NSString*>* parts = [pose componentsSeparatedByString:@","];
        if (parts.count == 3) {
            [_globe focusLatitude:parts[0].doubleValue
                        longitude:parts[1].doubleValue
                         distance:(float)parts[2].doubleValue];
        }
    }
    NSString* query = environment[@"CAELUS_SNAPSHOT_QUERY"];
    const BOOL selectFirst = [environment[@"CAELUS_SNAPSHOT_SELECT"] isEqualToString:@"1"];

    // The catalog arrives after launch, so the query and selection are applied
    // just before the capture rather than at launch time.
    __weak AppController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AppController* self2 = weakSelf;
        if (self2 == nil) return;
        if (query.length > 0) {
            self2->_searchField.stringValue = query;
            [self2 reloadSearch];
        }
        if (selectFirst && !self2->_searchResults.empty()) {
            [self2 selectIndex:(NSInteger)self2->_searchResults.front()];
            [self2 restoreSelectionInTable];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf writeSnapshotTo:path];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
    });
}

@end
