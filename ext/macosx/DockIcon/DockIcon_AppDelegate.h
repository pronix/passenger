//
//  DockIcon_AppDelegate.h
//  Phusion Passenger OS X integration
//
//  Created by Ninh Bui on 1/12/10.
//  Copyright 2010 Phusion v.o.f.. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AboutWindowController.h"

enum {
	PhusionPassengerLiteFD  = 1,
	PhusionPassengerLitePID = 2
};

@interface DockIcon_AppDelegate : NSObject <NSApplicationDelegate> {
	// The thread object responsible for exiting the application. When the user
	// provided fd becomes readable, it will terminate the application.
	NSThread *exitThread;
	AboutWindowController *aboutWindowController;
}

-(IBAction)orderFrontAboutWindow:(id)sender;

@end
