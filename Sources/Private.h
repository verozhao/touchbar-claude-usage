#import <AppKit/AppKit.h>

// Private DFRFoundation / AppKit API used by Pock, MTMR and Touch Bar Simulator
// to present a full-width "system modal" Touch Bar and a Control Strip tray item.
extern void DFRElementSetControlStripPresenceForIdentifier(NSString *identifier, BOOL enabled);
extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL enabled);

@interface NSTouchBar (ClaudeTouchBarPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

@interface NSTouchBarItem (ClaudeTouchBarPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end
