//
//  ViewController.h
//  YourJoke
//
//  Created by Kristina Šlekytė on 28/11/15.
//  Copyright (c) 2015 Darius Miliauskas. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <OpenEars/OEEventsObserver.h>

@interface ViewController : UIViewController <OEEventsObserverDelegate>

@property (strong, nonatomic) OEEventsObserver *openEarsEventsObserver;


@end
