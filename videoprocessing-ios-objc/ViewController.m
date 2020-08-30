//
//  ViewController.m
//  videoprocessing-ios-objc
//
//  Created by Matej Trbara on 29/08/2020.
//  Copyright © 2020 Kodbiro. All rights reserved.
//

#import "ViewController.h"
#import <DeepAR/ARView.h>
#import <DeepAR/CameraController.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "OffscreenProcessingViewController.h"

#define USE_EXTERNAL_CAMERA 0
#define ITEMS_PER_ROW ((CGFloat)3)
#define SECTION_INSETS (UIEdgeInsetsMake(20.0, 20.0, 20.0, 20.0))

@interface Effect : NSObject

@property (nonatomic, strong) NSString* name;
@property (nonatomic, strong) NSString* path;
@property (nonatomic, strong) NSString* thumbnail;

- (instancetype)initWithName:(NSString*)name path:(NSString*)path thumbnail:(NSString*)thumbnail;

@end

@implementation Effect

- (instancetype)initWithName:(NSString *)name path:(NSString *)path thumbnail:(NSString *)thumbnail {
    self = [super init];
    if (self) {
        self.name = name;
        self.path = path;
        self.thumbnail = thumbnail;
    }
    return self;
}

@end

@interface FilterCellView : UICollectionViewCell

@property (nonatomic, weak) IBOutlet UIImageView* imageView;
@property (nonatomic, weak) IBOutlet UIImageView* checkMark;

@end

@implementation FilterCellView

@end

@interface ViewController () <DeepARDelegate, UICollectionViewDelegateFlowLayout, UINavigationControllerDelegate, UIImagePickerControllerDelegate> {
    NSTimer* timer;
    CVPixelBufferRef selfie;
    BOOL liveMode;
    BOOL offscreen;
}

@property (nonatomic, strong) DeepAR* deepAR;
@property (nonatomic, assign) NSInteger currentEffect;
@property (nonatomic, strong) NSMutableArray* effects;
@property (nonatomic, weak) IBOutlet UIBarButtonItem* pickVideoButton;


@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.deepAR = [[DeepAR alloc] init];
    [self.deepAR setLicenseKey:@"your_license_key_goes_here"];
    self.deepAR.delegate = self;
    [self.deepAR changeLiveMode:NO];
    
    // Pre-initialize the offscreen rendering
    [self.deepAR initializeOffscreenWithWidth:1 height:1];
    [self.deepAR setParameterWithKey:@"synchronous_vision_initialization" value:@"true"];
    
    self.effects = [NSMutableArray array];
    self.currentEffect = -1;
    self.collectionView.allowsMultipleSelection = NO;

    [self.effects addObject:[[Effect alloc] initWithName:@"Aviators" path:[[NSBundle mainBundle] pathForResource:@"aviators" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"aviators_toothpick.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Big mouth" path:[[NSBundle mainBundle] pathForResource:@"bigmouth" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"become_a_big_mouth.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Dalmatian" path:[[NSBundle mainBundle] pathForResource:@"dalmatian" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"dalmatian_v2.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Flowers" path:[[NSBundle mainBundle] pathForResource:@"flowers" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"flowers.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Koala" path:[[NSBundle mainBundle] pathForResource:@"koala" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"koala.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Lion" path:[[NSBundle mainBundle] pathForResource:@"lion" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"lion.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Mud mask" path:[[NSBundle mainBundle] pathForResource:@"mudmask" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"mudmask.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Pug" path:[[NSBundle mainBundle] pathForResource:@"pug" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"pug_v2.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Sleeping mask" path:[[NSBundle mainBundle] pathForResource:@"sleepingmask" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"sleepingmask.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Small face" path:[[NSBundle mainBundle] pathForResource:@"smallface" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"smallface.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Triple face" path:[[NSBundle mainBundle] pathForResource:@"tripleface" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"tripleface.png" ofType:@""]]];
    [self.effects addObject:[[Effect alloc] initWithName:@"Twisted face" path:[[NSBundle mainBundle] pathForResource:@"twistedface" ofType:@""] thumbnail:[[NSBundle mainBundle] pathForResource:@"twistedface.png" ofType:@""]]];
    
    self.pickVideoButton.enabled = NO;
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.currentEffect > -1) {
        [self.collectionView deselectItemAtIndexPath:[NSIndexPath indexPathForItem:self.currentEffect inSection:0] animated:YES];
        [self collectionView:self.collectionView didDeselectItemAtIndexPath:[NSIndexPath indexPathForItem:self.currentEffect inSection:0]];
        self.currentEffect = -1;
        self.pickVideoButton.enabled = NO;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.effects.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    FilterCellView* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"FilterCell" forIndexPath:indexPath];

    Effect* effect = self.effects[indexPath.row];
    UIImage* image = [UIImage imageWithContentsOfFile:effect.thumbnail];
    
    UIGraphicsBeginImageContextWithOptions(cell.imageView.bounds.size, NO, 1.0);
    // Add a clip before drawing anything, in the shape of an rounded rect
    [[UIBezierPath bezierPathWithRoundedRect:cell.imageView.bounds
                                cornerRadius:50.0] addClip];
    // Draw your image
    [image drawInRect:cell.imageView.bounds];

    // Get the image, here setting the UIImageView image
    cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();

    // Lets forget about that we were drawing
    UIGraphicsEndImageContext();
    
    cell.checkMark.layer.cornerRadius = cell.checkMark.frame.size.width / 2.f;
    
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    self.currentEffect = indexPath.row;
    FilterCellView* cell = (FilterCellView*)[collectionView cellForItemAtIndexPath:indexPath];
    cell.imageView.layer.borderWidth = 3.0f;
    cell.imageView.layer.cornerRadius = [self calculateCellSize].height / 2.f;
    cell.imageView.layer.borderColor = [UIColor systemBlueColor].CGColor;
    cell.checkMark.hidden = NO;
    self.pickVideoButton.enabled = YES;
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    FilterCellView* cell = (FilterCellView*)[collectionView cellForItemAtIndexPath:indexPath];
    cell.imageView.layer.borderWidth = 0.f;
    cell.imageView.layer.cornerRadius = 0.f;
    cell.imageView.layer.borderColor = [UIColor clearColor].CGColor;
    cell.checkMark.hidden = YES;
}

- (CGSize)calculateCellSize {
    CGFloat paddingSpace = SECTION_INSETS.left * (ITEMS_PER_ROW + 1);
    CGFloat availableWidth = self.view.frame.size.width - paddingSpace;
    CGFloat widthPerItem = availableWidth / ITEMS_PER_ROW;
    
    return CGSizeMake(widthPerItem, widthPerItem);
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    return [self calculateCellSize];
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    return SECTION_INSETS;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    return SECTION_INSETS.left;
}

- (void)dealloc {
    [self.deepAR shutdown];
}

- (void)didInitialize {
    [self.deepAR showStats:YES];
    [self.deepAR setFaceDetectionSensitivity:3];
}

- (IBAction)pickVideo:(id)sender {
    Effect* effect = self.effects[self.currentEffect];
    [self.deepAR switchEffectWithSlot:@"mask" path:effect.path];
    
    // Present videos from which to choose
    UIImagePickerController *videoPicker = [[UIImagePickerController alloc] init];
    videoPicker.delegate = self; // ensure you set the delegate so when a video is chosen the right method can be called

    videoPicker.modalPresentationStyle = UIModalPresentationCurrentContext;
    // This code ensures only videos are shown to the end user
    videoPicker.mediaTypes = @[(NSString*)kUTTypeMovie, (NSString*)kUTTypeAVIMovie, (NSString*)kUTTypeVideo, (NSString*)kUTTypeMPEG4];

    videoPicker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    [self presentViewController:videoPicker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    NSURL *videoURL = [info objectForKey:UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES completion:NULL];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *videoOuputFile = [documentsDirectory stringByAppendingPathComponent: @"video_output.mov"];
    NSURL* outputURL = [NSURL fileURLWithPath:videoOuputFile];
    
    
    OffscreenProcessingViewController* process = (OffscreenProcessingViewController*) [self.storyboard instantiateViewControllerWithIdentifier:@"processOffscreenID"];
    process.deepAR = self.deepAR;
    process.inputVideoURL = videoURL;
    process.outputVideoURL = outputURL;
    [self.navigationController pushViewController:process animated:YES];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:NULL];
}

- (void)frameAvailable:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    CIContext *temporaryContext = [CIContext contextWithOptions:nil];
    CGImageRef videoImage = [temporaryContext
                             createCGImage:ciImage
                             fromRect:CGRectMake(0, 0,
                                                 CVPixelBufferGetWidth(pixelBuffer),
                                                 CVPixelBufferGetHeight(pixelBuffer))];
    
    
    UIImage *uiImage = [UIImage imageWithCGImage:videoImage];
    CGImageRelease(videoImage);
}


@end
