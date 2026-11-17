// The settings page. It stands in for upstream's src/Settings/TweakSettings.m
// (left out of the build in ohrt/exclude.txt) and uses upstream's row types
// as they are.
//
// Rows from upstream are kept when their hooks still attach to the pinned
// Instagram version (ohrt/tools/hookaudit.py src) and dropped when they do
// not, so a switch here is never a switch to nothing.
#import <objc/runtime.h>

#import "../../src/Settings/TweakSettings.h"
#import "Ohrt.h"

static SCISetting *OhrtSwitch(NSString *title, NSString *subtitle, NSString *key) {
    return [SCISetting switchCellWithTitle:title subtitle:subtitle defaultsKey:key];
}

static SCISetting *OhrtRestartSwitch(NSString *title, NSString *subtitle, NSString *key) {
    return [SCISetting switchCellWithTitle:title subtitle:subtitle defaultsKey:key requiresRestart:YES];
}

static SCISetting *OhrtPage(NSString *title, NSString *symbol, NSArray *sections) {
    return [SCISetting navigationCellWithTitle:title subtitle:@"" icon:[SCISymbol symbolWithName:symbol] navSections:sections];
}

static NSDictionary *OhrtSection(NSString *header, NSArray *rows, NSString *footer) {
    return @{ @"header" : header ?: @"", @"rows" : rows, @"footer" : footer ?: @"" };
}

@implementation SCITweakSettings

+ (NSString *)title {
    return @"ohrtstagram";
}

+ (NSArray *)focusSections {
    return @[
        OhrtSection(@"Time", @[
            [SCISetting staticCellWithTitle:@"Today" subtitle:OhrtFormatDuration(OhrtTimeSpentToday()) icon:[SCISymbol symbolWithName:@"clock"]],
            [SCISetting stepperCellWithTitle:@"Daily time budget" subtitle:@"%@ %@ a day" defaultsKey:kOhrtBudgetMinutesKey
                                         min:0 max:240 step:5 label:@"minutes" singularLabel:@"minute"],
        ], @"At zero there is no budget. Past it, a screen covers the app; it always offers five more minutes."),
        OhrtSection(@"Feed", @[
            OhrtRestartSwitch(@"Following feed", @"Home shows only accounts you follow, newest first", kOhrtFollowingFeedKey),
            OhrtRestartSwitch(@"Caught up wall", @"The feed ends where you had caught up to last time", kOhrtWallKey),
            OhrtRestartSwitch(@"Hidden like counts", @"Counts who liked a post that hides its count, a few seconds apart, and shows it under the post", kOhrtLikesKey),
        ], @"The wall uses the following feed whether or not that switch is on."),
        OhrtSection(@"Mode", @[
            OhrtRestartSwitch(@"DM mode", @"Opens on your messages, with the home tab hidden", kOhrtDMModeKey),
        ], nil),
        OhrtSection(@"Facts", @[
            OhrtRestartSwitch(@"Facts on a profile", @"Above a profile's buttons: the account's id and kind, what changed since you last looked, and your history with it", kOhrtFactsKey),
            OhrtRestartSwitch(@"Facts on a post", @"Under a post's buttons: when it was made and posted, exact counts, and what Insta\u2060gram's AI sees in it", kOhrtPostFactsKey),
            [SCISetting staticCellWithTitle:@"Your export" subtitle:OhrtExportStatus() icon:nil],
            [SCISetting buttonCellWithTitle:@"Read in an export" subtitle:@"Unpack its zip in Files, then pick the folder" icon:nil action:^{
                OhrtExportImport();
            }],
        ], @"What an account is comes from the app as its profile opens. When you followed each other and how much you have liked and written "
           @"comes from your Insta\u2060gram export, which holds what the app does not, and from what you do here after it was made. "
           @"Stories watched are counted here only, since the export lists too few of them. "
           @"Every count is of what you did. All of it stays on this phone."),
        OhrtSection(@"Look", @[
            OhrtRestartSwitch(@"ohrtstagram marks", @"Our wordmark at the top of the home feed and our mark on the login screen", kOhrtWordmarkKey),
            OhrtRestartSwitch(@"ohrtstagram in text", @"Buttons, titles and menus say ohrtstagram", kOhrtNameKey),
            OhrtSwitch(@"Grayscale", @"Shows the whole app in gray", kOhrtGrayscaleKey),
            OhrtRestartSwitch(@"About you tab", @"A tab after home with what Insta\u2060gram keeps about you", kOhrtAboutTabKey),
        ], nil),
    ];
}

+ (NSArray *)sections {
    // Whoever got as far as opening this page has an app that started.
    OhrtLaunchSettled();
    NSMutableArray *sections = [NSMutableArray array];

    [sections addObject:OhrtSection(nil, @[
        OhrtPage(@"Focus", @"moon", [self focusSections]),
        [SCISetting navigationCellWithTitle:@"Follow back" subtitle:@"" icon:[SCISymbol symbolWithName:@"person.2"]
                             viewController:OhrtFollowBackScreen()],
    ], nil)];

    [sections addObject:OhrtSection(@"Insta\u2060gram", @[
        OhrtPage(@"General", @"gear", @[
            OhrtSection(nil, @[
                OhrtSwitch(@"Hide ads", @"Removes ads from the feed, stories and search", @"hide_ads"),
                OhrtSwitch(@"Hide Meta AI", @"Hides the Meta AI buttons and suggestions", @"hide_meta_ai"),
                OhrtSwitch(@"Copy description", @"Hold a caption or bio to copy it", @"copy_description"),
                OhrtSwitch(@"Do not save recent searches", @"Search bars stop remembering what you looked for", @"no_recent_searches"),
                OhrtSwitch(@"Detailed color picker", @"Hold the eyedropper in the story editor for any color", @"detailed_color_picker"),
                OhrtRestartSwitch(@"Liquid glass buttons", @"Insta\u2060gram's experimental glass buttons", @"liquid_glass_buttons"),
                OhrtRestartSwitch(@"Liquid glass surfaces", @"The same for menus and other surfaces", @"liquid_glass_surfaces"),
            ], nil),
            OhrtSection(@"Notes", @[
                OhrtSwitch(@"Hide notes tray", @"Hides the notes above your messages", @"hide_notes_tray"),
                OhrtSwitch(@"Hide friends map", @"Hides the map in the notes tray", @"hide_friends_map"),
                OhrtSwitch(@"Note theming", @"Turns on the notes theme picker", @"enable_notes_customization"),
                OhrtSwitch(@"Custom note themes", @"Your own emoji and colors for notes", @"custom_note_themes"),
            ], nil),
            OhrtSection(@"Suggestions", @[
                OhrtSwitch(@"No suggested users", @"Hides accounts suggested for you to follow, outside the feed", @"no_suggested_users"),
                OhrtSwitch(@"No suggested chats", @"Hides suggested broadcast channels in messages", @"no_suggested_chats"),
                OhrtSwitch(@"Hide explore grid", @"Search opens without the grid of suggested posts", @"hide_explore_grid"),
            ], nil),
        ]),
        OhrtPage(@"Feed", @"rectangle.stack", @[
            OhrtSection(nil, @[
                OhrtSwitch(@"No suggested posts", @"Removes suggested posts from the feed", @"no_suggested_post"),
                OhrtSwitch(@"No suggested accounts", @"Removes the rows of accounts to follow", @"no_suggested_account"),
                OhrtSwitch(@"No suggested reels", @"Removes the rows of reels to watch", @"no_suggested_reels"),
                OhrtSwitch(@"No suggested Threads posts", @"Removes Threads posts from the feed", @"no_suggested_threads"),
                OhrtSwitch(@"Hide stories tray", @"Hides the stories at the top of the feed", @"hide_stories_tray"),
                OhrtSwitch(@"Hide entire feed", @"Leaves the home tab empty", @"hide_entire_feed"),
                OhrtSwitch(@"Disable video autoplay", @"Videos in the feed wait for a tap", @"disable_feed_autoplay"),
            ], nil),
        ]),
        OhrtPage(@"Reels", @"film.stack", @[
            OhrtSection(@"Limits", @[
                OhrtRestartSwitch(@"Hide reels tab", @"Takes Reels out of the tab bar", @"hide_reels_tab"),
                OhrtRestartSwitch(@"Disable scrolling reels", @"A reel someone sent you plays; the next one does not follow", @"disable_scrolling_reels"),
                OhrtSwitch(@"Prevent doom scrolling", @"Loads only a few reels at a time and blocks refreshing", @"prevent_doom_scrolling"),
                [SCISetting stepperCellWithTitle:@"Doom scrolling limit" subtitle:@"Loads %@ %@" defaultsKey:@"doom_scrolling_reel_count"
                                             min:1 max:100 step:1 label:@"reels" singularLabel:@"reel"],
            ], nil),
            OhrtSection(@"Playback", @[
                [SCISetting menuCellWithTitle:@"Tap controls" subtitle:@"What a tap on a reel does" menu:[self menus][@"reels_tap_control"]],
                OhrtSwitch(@"Always show progress scrubber", @"Shows the progress bar on every reel", @"reels_show_scrubber"),
                OhrtRestartSwitch(@"Disable auto-unmuting", @"The volume and silent buttons stop unmuting reels", @"disable_auto_unmuting_reels"),
                OhrtSwitch(@"Confirm reel refresh", @"Asks before refreshing reels", @"refresh_reel_confirm"),
                OhrtSwitch(@"Hide reels header", @"Hides the bar at the top while watching reels", @"hide_reels_header"),
                OhrtSwitch(@"Hide reels blend button", @"Hides the blend button in messages", @"hide_reels_blend"),
            ], nil),
        ]),
        OhrtPage(@"Saving", @"tray.and.arrow.down", @[
            OhrtSection(nil, @[
                OhrtSwitch(@"Download feed posts", @"Hold a post with your fingers to save it", @"dw_feed_posts"),
                OhrtSwitch(@"Download reels", @"Hold a reel to save it", @"dw_reels"),
                OhrtSwitch(@"Download stories", @"Hold a story to save it", @"dw_story"),
                OhrtSwitch(@"Save profile picture", @"Open a profile picture, then hold it to save", @"save_profile"),
            ], nil),
            OhrtSection(@"Gesture", @[
                [SCISetting stepperCellWithTitle:@"Fingers" subtitle:@"Saves with %@ %@" defaultsKey:@"dw_finger_count"
                                             min:1 max:5 step:1 label:@"fingers" singularLabel:@"finger"],
                [SCISetting stepperCellWithTitle:@"Hold time" subtitle:@"Hold for %@ %@" defaultsKey:@"dw_finger_duration"
                                             min:0 max:10 step:0.25 label:@"sec" singularLabel:@"sec"],
            ], nil),
        ]),
        OhrtPage(@"Stories and messages", @"rectangle.portrait.on.rectangle.portrait.angled", @[
            OhrtSection(@"What you send back", @[
                OhrtSwitch(@"Mark messages seen by hand", @"Adds a button to chats; nothing is marked seen until you press it", @"remove_lastseen"),
                OhrtSwitch(@"Disable typing status", @"Others do not see when you are typing", @"disable_typing_status"),
                OhrtSwitch(@"Disable story seen receipt", @"Others do not see that you viewed their story", @"no_seen_receipt"),
            ], nil),
            OhrtSection(nil, @[
                OhrtRestartSwitch(@"Disable instants creation", @"Hides the ways to make and send instants", @"disable_instants_creation"),
            ], nil),
        ]),
        OhrtPage(@"Navigation", @"hand.draw.fill", @[
            OhrtSection(nil, @[
                [SCISetting menuCellWithTitle:@"Icon order" subtitle:@"The order of the tabs" menu:[self menus][@"nav_icon_ordering"]],
                [SCISetting menuCellWithTitle:@"Swipe between tabs" subtitle:@"Swipe sideways to change tab" menu:[self menus][@"swipe_nav_tabs"]],
            ], nil),
            OhrtSection(@"Hiding tabs", @[
                OhrtRestartSwitch(@"Hide feed tab", @"", @"hide_feed_tab"),
                OhrtRestartSwitch(@"Hide explore tab", @"", @"hide_explore_tab"),
                OhrtRestartSwitch(@"Hide create tab", @"", @"hide_create_tab"),
            ], @"Reels has its own page."),
        ]),
        OhrtPage(@"Confirm actions", @"checkmark", @[
            OhrtSection(nil, @[
                OhrtSwitch(@"Confirm like: posts and stories", @"", @"like_confirm"),
                OhrtSwitch(@"Confirm like: reels", @"", @"like_confirm_reels"),
                OhrtSwitch(@"Confirm follow", @"", @"follow_confirm"),
                OhrtSwitch(@"Confirm repost", @"", @"repost_confirm"),
                OhrtSwitch(@"Confirm call", @"", @"call_confirm"),
                OhrtSwitch(@"Confirm voice messages", @"", @"voice_message_confirm"),
                OhrtSwitch(@"Confirm follow requests", @"", @"follow_request_confirm"),
                OhrtSwitch(@"Confirm vanish mode", @"", @"shh_mode_confirm"),
                OhrtSwitch(@"Confirm posting a comment", @"", @"post_comment_confirm"),
                OhrtSwitch(@"Confirm changing chat theme", @"", @"change_direct_theme_confirm"),
                OhrtSwitch(@"Confirm sticker taps", @"", @"sticker_interact_confirm"),
            ], @"Each asks \"Are you sure?\" before the action goes through."),
        ]),
    ], nil)];

    NSMutableArray *debug = [NSMutableArray array];
    // FLEX is only in builds made with --flex.
    if (objc_getClass("FLEXManager")) {
        [debug addObject:OhrtSection(@"FLEX", @[
            OhrtSwitch(@"FLEX gesture", @"Hold five fingers on the screen to open the inspector", @"flex_instagram"),
            OhrtSwitch(@"Open FLEX on launch", @"", @"flex_app_launch"),
            OhrtSwitch(@"Open FLEX on focus", @"", @"flex_app_start"),
        ], nil)];
    }
    [debug addObject:OhrtSection(nil, @[
        OhrtRestartSwitch(@"Settings from the home tab", @"Hold the home tab to open these settings", @"settings_shortcut"),
        OhrtSwitch(@"Disable safe mode", @"Insta\u2060gram stops resetting itself after repeated crashes", @"disable_safe_mode"),
    ], nil)];
    [debug addObject:OhrtSection(@"Self-check", @[
        [SCISetting staticCellWithTitle:@"This Insta\u2060gram" subtitle:OhrtSelfCheck() icon:nil],
        [SCISetting buttonCellWithTitle:@"Copy" subtitle:@"" icon:nil action:^{
            [UIPasteboard generalPasteboard].string = OhrtSelfCheck();
        }],
    ], @"What each ohrtstagram feature needs from Insta\u2060gram, looked up in the app that is running.")];
    [sections addObject:OhrtSection(nil, @[ OhrtPage(@"Debug", @"ladybug", debug) ], nil)];

    [sections addObject:OhrtSection(@"About", @[
        [SCISetting linkCellWithTitle:@"ohrtstagram" subtitle:@"The source, on GitHub"
                                 icon:[SCISymbol symbolWithName:@"chevron.left.forwardslash.chevron.right"]
                                  url:@"https://github.com/Lavanic/ohrtstagram"],
    ], [NSString stringWithFormat:@"ohrtstagram %@, a modified SCInsta %@, on Insta\u2060gram %@.\nFree software under the GNU GPL, version 3.",
                                  OHRT_VERSION, SCIVersionString, [SCIUtils IGVersionString]])];

    return sections;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

static UICommand *OhrtChoice(NSString *title, NSString *key, NSString *value) {
    return [UICommand commandWithTitle:title image:nil action:@selector(menuChanged:)
                          propertyList:@{ @"defaultsKey" : key, @"value" : value, @"requiresRestart" : @YES }];
}

static UIMenu *OhrtMenu(NSString *key, NSArray<NSArray<NSString *> *> *choices) {
    NSMutableArray *rest = [NSMutableArray array];
    for (NSArray<NSString *> *choice in choices) [rest addObject:OhrtChoice(choice[0], key, choice[1])];
    return [UIMenu menuWithChildren:@[
        OhrtChoice(@"Default", key, @"default"),
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:rest],
    ]];
}

+ (NSDictionary *)menus {
    return @{
        @"reels_tap_control" : OhrtMenu(@"reels_tap_control", @[ @[ @"Pause/Play", @"pause" ], @[ @"Mute/Unmute", @"mute" ] ]),
        @"nav_icon_ordering" : OhrtMenu(@"nav_icon_ordering", @[ @[ @"Classic", @"classic" ], @[ @"Standard", @"standard" ], @[ @"Alternate", @"alternate" ] ]),
        @"swipe_nav_tabs" : OhrtMenu(@"swipe_nav_tabs", @[ @[ @"Enabled", @"enabled" ], @[ @"Disabled", @"disabled" ] ]),
    };
}

#pragma clang diagnostic pop

@end
