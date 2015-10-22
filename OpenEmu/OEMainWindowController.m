/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEMainWindowController.h"
#import "OEMainWindowContentController.h"

#import "NSImage+OEDrawingAdditions.h"
#import "OEMainWindow.h"
#import "NSWindow+OEFullScreenAdditions.h"
#import "OESetupAssistant.h"
#import "OECoreUpdater.h"
#import "OELibraryController.h"

#import "NSDocumentController+OEAdditions.h"
#import "OEGameDocument.h"
#import "OEGameCoreManager.h"
#import "OEGameViewController.h"

#import "OEHUDAlert+DefaultAlertsAdditions.h"
#import "OEDBGame.h"

#import "NSView+FadeImage.h"
#import "OEFadeView.h"

NSString *const OEForcePopoutGameWindowKey = @"forcePopout";
NSString *const OEFullScreenGameWindowKey  = @"fullScreen";
NSString *const OEMainWindowFullscreenKey  = @"mainWindowFullScreen";

NSString *const OEDefaultWindowTitle       = @"OpenEmu";

#define MainMenu_Window_OpenEmuTag 501

@interface OEMainWindowController () <OELibraryControllerDelegate>
{
    OEGameDocument *_gameDocument;
    BOOL            _shouldExitFullScreenWhenGameFinishes;
    BOOL            _shouldUndockGameWindowOnFullScreenExit;
    BOOL            _resumePlayingAfterFullScreenTransition;

    BOOL _isLaunchingGame;
}

@end

@implementation OEMainWindowController

- (void)dealloc
{
    _currentContentController = nil;
    [self setDefaultContentController:nil];
    [self setLibraryController:nil];
    [self setPlaceholderView:nil];
}

- (id)initWithWindow:(NSWindow *)window
{
    if((self = [super initWithWindow:window]) == nil)
        return nil;

    // Since restoration from autosave happens before NSWindowController
    // receives -windowDidLoad and we are autosaving the window size, we
    // need to set allowWindowResizing to YES before -windowDidLoad
    _allowWindowResizing = YES;

    return self;
}


- (void)awakeFromNib
{
    [super awakeFromNib];
    
    [self setUpLibraryController];
    [self setUpWindow];
    [self setUpCurrentContentController];
    [self setUpViewMenuItemBindings];
    [self setUpToolbarButtonTooltips];

    _isLaunchingGame = NO;
}

- (void)setUpLibraryController
{
    OELibraryController *libraryController = [self libraryController];
    
    [libraryController setDelegate:self];
}

- (void)setUpWindow
{    
    NSWindow *window = [self window];
    
    [window setDelegate:self];
    
    [window setRestorable:NO];
    [window setExcludedFromWindowsMenu:YES];
    [window setTitleVisibility:NSWindowTitleHidden];
    [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameVibrantDark]];
    [window setToolbar:nil];
}

- (void)setUpCurrentContentController
{
    if(![[NSUserDefaults standardUserDefaults] boolForKey:OESetupAssistantHasFinishedKey])
    {
        OESetupAssistant *setupAssistant = [[OESetupAssistant alloc] init];
        [setupAssistant setCompletionBlock:
         ^(BOOL discoverRoms, NSArray *volumes)
         {
             if(discoverRoms)
                 [[[OELibraryDatabase defaultDatabase] importer] discoverRoms:volumes];
             [self setCurrentContentController:[self libraryController] animate:NO];

             NSWindow *window = [self window];
             [window setToolbar:[[NSToolbar alloc] initWithIdentifier:@""]];
         }];
        
        [[self window] center];
        
        [self setCurrentContentController:setupAssistant];
    }
    else
    {
        NSWindow *window = [self window];
        [window setToolbar:[[NSToolbar alloc] initWithIdentifier:@""]];

        [self setCurrentContentController:[self libraryController] animate:NO];
    }
}

- (void)setUpViewMenuItemBindings
{
    NSMenu *viewMenu = [[[NSApp mainMenu] itemAtIndex:3] submenu];
    NSMenuItem *showLibraryNames = [viewMenu itemWithTag:10];
    NSMenuItem *showRomNames     = [viewMenu itemWithTag:11];
    NSMenuItem *undockGameWindow = [viewMenu itemWithTag:3];
    
    NSDictionary *negateOptions = @{NSValueTransformerNameBindingOption:NSNegateBooleanTransformerName};
    [showLibraryNames bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:negateOptions];
    [showRomNames     bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:negateOptions];
    [undockGameWindow bind:@"enabled" toObject:self withKeyPath:@"mainWindowRunsGame" options:@{}];
}

- (void)setUpToolbarButtonTooltips
{
    [_toolbarGridViewButton setToolTip:NSLocalizedString(@"Switch To Grid View", @"Tooltip")];
    [_toolbarGridViewButton setToolTipStyle:OEToolTipStyleDefault];
    
    [_toolbarListViewButton setToolTip:NSLocalizedString(@"Switch To List View", @"Tooltip")];
    [_toolbarListViewButton setToolTipStyle:OEToolTipStyleDefault];
    
    [_toolbarAddToSidebarButton setToolTip:NSLocalizedString(@"New Collection", @"Tooltip")];
    [_toolbarAddToSidebarButton setToolTipStyle:OEToolTipStyleDefault];
}

- (NSString *)windowNibName
{
    return @"MainWindow";
}

- (void)windowDidLoad
{
    NSLog(@"window did load");
}

#pragma mark -
// ugly hack, remove
- (void)startGame:(OEDBGame*)game
{
    [self OE_openGameDocumentWithGame:game saveState:[game autosaveForLastPlayedRom]];
}

#pragma mark -

- (void)setCurrentContentController:(NSViewController *)controller animate:(BOOL)shouldAnimate
{
    if(controller == nil) controller = [self libraryController];
    if(controller == [self currentContentController]) return;

    NSView *placeHolderView = [self placeholderView];

    // We use Objective-C blocks to factor out common code used in both animated and non-animated controller switching
    void (^sendViewWillDisappear)(void) =
    ^{
        [_currentContentController viewWillDisappear];
        [controller viewWillAppear];
    };

    void (^replaceController)(NSView *) =
    ^(NSView *viewToReplace)
    {
        [[controller view] setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [[controller view] setFrame:[placeHolderView bounds]];

        if(viewToReplace)
            [placeHolderView replaceSubview:viewToReplace with:[controller view]];
        else
            [placeHolderView addSubview:[controller view]];

        [[self window] makeFirstResponder:[controller view]];

        [_currentContentController viewDidDisappear];
        [controller viewDidAppear];
        _currentContentController = controller;

        [viewToReplace removeFromSuperview];
        NSWindow *window = [self window];

        if(controller == [_gameDocument gameViewController])
        {
            [window setToolbar:nil];
            [window setTitleVisibility:NSWindowTitleVisible];
            [_gameDocument setGameWindowController:self];
            [_gameDocument setEmulationPaused:NO];
        }
        else
        {
            [window setTitleVisibility:NSWindowTitleHidden];

            if(controller == [self libraryController]){
                [window setToolbar:[[NSToolbar alloc] initWithIdentifier:@""]];
            }

            [window setTitle:OEDefaultWindowTitle];
#if DEBUG_PRINT
            [window setTitle:[[window title] stringByAppendingString:@" (DEBUG BUILD)"]];
#endif
        }
    };

    if(shouldAnimate)
    {
        NSImage *currentState = [[self placeholderView] fadeImage];
        NSImage *newState = nil;
        if([_currentContentController respondsToSelector:@selector(setCachedSnapshot:)])
            [(id<OEMainWindowContentController>)_currentContentController setCachedSnapshot:currentState];

        sendViewWillDisappear();

        OEFadeView *fadeView = [[OEFadeView alloc] initWithFrame:[placeHolderView bounds]];

        if(_currentContentController)
            [_placeholderView replaceSubview:[_currentContentController view] with:fadeView];
        else
            [_placeholderView addSubview:fadeView];

        if([controller respondsToSelector:@selector(cachedSnapshot)])
            newState = [(id <OEMainWindowContentController>)controller cachedSnapshot];

        [fadeView fadeFromImage:currentState toImage:newState callback:
         ^{
             replaceController(fadeView);
         }];
    }
    else
    {
        sendViewWillDisappear();
        replaceController([_currentContentController view]);
    }
}

- (void)setCurrentContentController:(NSViewController *)newCurrentContentController
{
    [self setCurrentContentController:newCurrentContentController animate:YES];
}

- (IBAction)undockGameWindow:(id)sender
{
    _mainWindowRunsGame = NO;

    if(_shouldExitFullScreenWhenGameFinishes && [[self window] isFullScreen])
    {
        [[self window] toggleFullScreen:self];
        _shouldExitFullScreenWhenGameFinishes = NO;
        _shouldUndockGameWindowOnFullScreenExit = YES;
    }
    else
    {
        [_gameDocument setEmulationPaused:YES];
        [self setCurrentContentController:nil];
        [_gameDocument setGameWindowController:nil];

        [_gameDocument showInSeparateWindowInFullScreen:NO];
        _gameDocument = nil;
    }
}

#pragma mark - OELibraryControllerDelegate protocol conformance

- (void)OE_openGameDocumentWithGame:(OEDBGame *)game saveState:(OEDBSaveState *)state
{
    // make sure we don't launch a game multiple times :/
    if(_isLaunchingGame) return;
    _isLaunchingGame = YES;

    NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
    BOOL openInSeparateWindow = _mainWindowRunsGame || [standardDefaults boolForKey:OEForcePopoutGameWindowKey];
    BOOL fullScreen = [standardDefaults boolForKey:OEFullScreenGameWindowKey];

    _shouldExitFullScreenWhenGameFinishes = NO;
    void (^openDocument)(OEGameDocument *, NSError *) =
    ^(OEGameDocument *document, NSError *error)
    {
        _isLaunchingGame = NO;
        if(document == nil)
        {
            if([[error domain] isEqualToString:OEGameDocumentErrorDomain] && [error code] == OEFileDoesNotExistError)
            {
                [game setStatus:@(OEDBGameStatusAlert)];
                [game save];

                NSString *messageText = [NSString stringWithFormat:NSLocalizedString(@"The game '%@' could not be started because a rom file could not be found. Do you want to locate it?", @""), [game name]];
                if([[OEHUDAlert alertWithMessageText:messageText
                                       defaultButton:NSLocalizedString(@"Locate", @"")
                                     alternateButton:NSLocalizedString(@"Cancel", @"")] runModal] == NSAlertFirstButtonReturn)
                {
                    OEDBRom  *missingRom = [[game roms] anyObject];
                    NSURL   *originalURL = [missingRom URL];
                    NSString  *extension = [originalURL pathExtension];

                    NSString *panelTitle = [NSString stringWithFormat:NSLocalizedString(@"Locate '%@'", @"Locate panel title"), [[originalURL pathComponents] lastObject]];
                    NSOpenPanel  *panel = [NSOpenPanel openPanel];
                    [panel setTitle:panelTitle];
                    [panel setCanChooseDirectories:NO];
                    [panel setCanChooseFiles:YES];
                    [panel setDirectoryURL:[originalURL URLByDeletingLastPathComponent]];
                    [panel setAllowsOtherFileTypes:NO];
                    [panel setAllowedFileTypes:@[extension]];

                    if([panel runModal] == NSModalResponseOK)
                    {
                        [missingRom setURL:[panel URL]];
                        [missingRom save];
                        [self OE_openGameDocumentWithGame:game saveState:state];
                    }
                }
            }
            else if(error)
                [self presentError:error];

            return;
        }
        else if ([[game status] intValue] == OEDBGameStatusAlert)
        {
            [game setStatus:@(OEDBGameStatusOK)];
            [game save];
        }
        
        if(openInSeparateWindow) return;

        _shouldExitFullScreenWhenGameFinishes = ![[self window] isFullScreen];
        _gameDocument = document;
        _mainWindowRunsGame = YES;

        while([[[self window] titlebarAccessoryViewControllers] count])
            [[self window] removeTitlebarAccessoryViewControllerAtIndex:0];
        [[self window] setToolbar:nil];

        if(fullScreen && ![[self window] isFullScreen])
        {
            [NSApp activateIgnoringOtherApps:YES];

            [self setCurrentContentController:[document gameViewController] animate:NO];
            [document setEmulationPaused:NO];
            [[self window] toggleFullScreen:self];
        }
        else
        {
            [document setGameWindowController:self];
            [self setCurrentContentController:[document gameViewController]];
        }
    };

    if(state != nil || ((state=[game autosaveForLastPlayedRom]) && [[OEHUDAlert loadAutoSaveGameAlert] runModal] == NSAlertFirstButtonReturn))
        [[NSDocumentController sharedDocumentController] openGameDocumentWithSaveState:state display:openInSeparateWindow fullScreen:fullScreen completionHandler:openDocument];
    else
        [[NSDocumentController sharedDocumentController] openGameDocumentWithGame:game display:openInSeparateWindow fullScreen:fullScreen completionHandler:openDocument];
}

- (void)libraryController:(OELibraryController *)sender didSelectGame:(OEDBGame *)game
{
    [self OE_openGameDocumentWithGame:game saveState:nil];
}

- (void)libraryController:(OELibraryController *)sender didSelectSaveState:(OEDBSaveState *)saveState
{
    [self OE_openGameDocumentWithGame:nil saveState:saveState];
}

#pragma mark - NSWindow delegate

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
    return [self allowWindowResizing] ? frameSize : [sender frame].size;
}

- (BOOL)windowShouldClose:(id)sender
{
    if([self currentContentController] == [self libraryController])
        return YES;
    else
    {
        [_gameDocument canCloseDocumentWithCompletionHandler:
         ^(NSDocument *document, BOOL shouldClose)
         {
             [_gameDocument setGameWindowController:nil];
             [_gameDocument close];
             _gameDocument = nil;
             _mainWindowRunsGame = NO;

             BOOL exitFullScreen = (_shouldExitFullScreenWhenGameFinishes && [[self window] isFullScreen]);
             if(exitFullScreen)
             {
                 [[self window] toggleFullScreen:self];
                 _shouldExitFullScreenWhenGameFinishes = NO;
             }

             [self setCurrentContentController:nil];
         }];

        return NO;
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    // Make sure the current content controller gets viewWillDisappear / viewDidAppear so it has a chance to store its state
    if([self currentContentController] == [self libraryController])
    {
        [[self libraryController] viewWillDisappear];
        [[self libraryController] viewDidDisappear];
        [[self libraryController] viewWillAppear];
        [[self libraryController] viewDidAppear];
    }

    [self setCurrentContentController:nil];
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    [[self currentContentController] viewWillAppear];
    [[self currentContentController] viewDidAppear];
}

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSApp mainMenu];

    NSMenu *windowMenu = [[mainMenu itemAtIndex:5] submenu];
    NSMenuItem *item = [windowMenu itemWithTag:MainMenu_Window_OpenEmuTag];
    [item setState:NSOnState];
}

- (void)windowDidResignMain:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSApp mainMenu];

    NSMenu *windowMenu = [[mainMenu itemAtIndex:5] submenu];
    NSMenuItem *item = [windowMenu itemWithTag:MainMenu_Window_OpenEmuTag];
    [item setState:NSOffState];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
    if(_gameDocument && [_gameDocument gameWindowController] == self)
    {
        _resumePlayingAfterFullScreenTransition = ![_gameDocument isEmulationPaused];
        [_gameDocument setEmulationPaused:YES];
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:OEMainWindowFullscreenKey];
    if(_gameDocument == nil) {
        return;
    }

    if(_shouldExitFullScreenWhenGameFinishes)
    {
        [_gameDocument setGameWindowController:self];
        [self setCurrentContentController:[_gameDocument gameViewController]];
    }

    if(_resumePlayingAfterFullScreenTransition)
        [_gameDocument setEmulationPaused:NO];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
    if(_gameDocument)
    {
        _resumePlayingAfterFullScreenTransition = ![_gameDocument isEmulationPaused];
        [_gameDocument setEmulationPaused:YES];
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:OEMainWindowFullscreenKey];

    if(_shouldUndockGameWindowOnFullScreenExit)
    {
        _shouldUndockGameWindowOnFullScreenExit = NO;

        [self setCurrentContentController:nil];

        [_gameDocument showInSeparateWindowInFullScreen:NO];

        if(_resumePlayingAfterFullScreenTransition)
            [_gameDocument setEmulationPaused:NO];

        _gameDocument = nil;
        _mainWindowRunsGame = NO;
    }
    else if(_gameDocument && _resumePlayingAfterFullScreenTransition)
        [_gameDocument setEmulationPaused:NO];
}

#pragma mark - Menu Items

- (IBAction)launchLastPlayedROM:(id)sender
{
    OEDBGame *game = [[sender representedObject] game];
    
    [self libraryController:nil didSelectGame:game];
}

- (IBAction)switchToGridView:(id)sender
{
    [[self toolbarListViewButton] setState:NSOffState];
    [[self toolbarGridViewButton] setState:NSOnState];
    [[self libraryController] switchToGridView:sender];
}

- (IBAction)switchToListView:(id)sender
{
    [[self toolbarGridViewButton] setState:NSOffState];
    [[self toolbarListViewButton] setState:NSOnState];
    [[self libraryController] switchToListView:sender];
}

@end
