//
//  OffscreenProcessingViewController.h
//  Example
//
//  Created by Kod Biro on 26/08/2020.
//  Copyright © 2020 MRRMRR. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <DeepAR/ARView.h>

NS_ASSUME_NONNULL_BEGIN

@interface OffscreenProcessingViewController : UIViewController

- (instancetype)init;

@property (nonatomic, weak) DeepAR* deepAR;
@property (nonatomic, strong) NSURL* inputVideoURL;
@property (nonatomic, strong) NSURL* outputVideoURL;

@end

NS_ASSUME_NONNULL_END
