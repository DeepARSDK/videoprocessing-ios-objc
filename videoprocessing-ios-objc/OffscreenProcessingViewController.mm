//
//  OffscreenProcessingViewController.m
//  Example
//
//  Created by Kod Biro on 26/08/2020.
//  Copyright © 2020 MRRMRR. All rights reserved.
//

#import "OffscreenProcessingViewController.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

@protocol SampleBufferChannelDelegate;

@interface SampleBufferChannel : NSObject {
    AVAssetReaderOutput        *assetReaderOutput;
    AVAssetWriterInput        *assetWriterInput;
    AVAssetWriterInputPixelBufferAdaptor *assetAdapterWriter;
    
    dispatch_block_t        completionHandler;
    dispatch_queue_t        serializationQueue;
    BOOL                    finished;  // only accessed on serialization queue
}
- (id)initWithAssetReaderOutput:(AVAssetReaderOutput *)assetReaderOutput assetWriterInput:(AVAssetWriterInput *)assetWriterInput;
- (id)initWithAssetReaderOutput:(AVAssetReaderOutput *)assetReaderOutput assetWriterInput:(AVAssetWriterInput *)assetWriterInput assetAdapterWriter:(AVAssetWriterInputPixelBufferAdaptor*)assetAdapterWriter;
@property (nonatomic, readonly) NSString *mediaType;
- (void)startWithDelegate:(id <SampleBufferChannelDelegate>)delegate completionHandler:(dispatch_block_t)completionHandler;  // delegate is retained until completion handler is called.  Completion handler is guaranteed to be called exactly once, whether reading/writing finishes, fails, or is cancelled.  Delegate may be nil.
- (void)cancel;
@end


@protocol SampleBufferChannelDelegate <NSObject>
@required
- (void)sampleBufferChannel:(SampleBufferChannel *)sampleBufferChannel didReadSampleBuffer:(CMSampleBufferRef)sampleBuffer;
@optional
- (void)sampleBufferChannel:(SampleBufferChannel *)sampleBufferChannel didReadSampleBuffer:(CMSampleBufferRef)sampleBuffer outputPixelBuffer:(CVPixelBufferRef*)outputPixelBuffer shouldFreePixelBuffer:(BOOL*)shouldFreePixelBuffer;
@end

@interface OffscreenProcessingViewController () <SampleBufferChannelDelegate> {
    AVAsset                        *asset;
    AVAssetImageGenerator        *imageGenerator;
    CMTimeRange                    timeRange;
    dispatch_queue_t            serializationQueue;

    // Only accessed on the main thread
    NSURL                        *outputURL;
    BOOL                        writingSamples;

    // All of these are createed, accessed, and torn down exclusively on the serializaton queue
    AVAssetReader                *assetReader;
    AVAssetWriter                *assetWriter;
    AVAssetWriterInputPixelBufferAdaptor *assetAdapterWriter;
    SampleBufferChannel        *audioSampleBufferChannel;
    SampleBufferChannel        *videoSampleBufferChannel;
    BOOL                        cancelled;
    
    CIContext* cicontext;
    NSInteger orientation;
}

- (void)setPreviewLayerContents:(id)contents gravity:(NSString *)gravity;
// These three methods are always called on the serialization dispatch queue
- (BOOL)setUpReaderAndWriterReturningError:(NSError **)outError;  // make sure "tracks" key of asset is loaded before calling this
- (BOOL)startReadingAndWritingReturningError:(NSError **)outError;
- (void)readingAndWritingDidFinishSuccessfully:(BOOL)success withError:(NSError *)error;
- (void)start;
- (void)cancel;

@property (nonatomic, weak) IBOutlet UIImageView* previewImage;
@property (nonatomic, weak) IBOutlet UIProgressView* progressBar;
@property (nonatomic, weak) IBOutlet UILabel* processingLabel;
@property (nonatomic, weak) IBOutlet UIActivityIndicatorView* activityIndicator;
@property (nonatomic, weak) IBOutlet UIVisualEffectView* blurView;

@end

@implementation OffscreenProcessingViewController

+ (NSArray *)readableTypes {
    return [AVURLAsset audiovisualTypes];
}

+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)typeName {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSString *serializationQueueDescription = [NSString stringWithFormat:@"%@ serialization queue", self];
    serializationQueue = dispatch_queue_create([serializationQueueDescription UTF8String], NULL);
    outputURL = self.outputVideoURL;
    NSDictionary *assetOptions = [NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:AVURLAssetPreferPreciseDurationAndTimingKey];
    asset = [AVURLAsset URLAssetWithURL:self.inputVideoURL options:assetOptions];
    if (asset) {
        imageGenerator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    }
    
    // Generate an image of some sort to use as a preview
    AVAsset *localAsset = asset;
    [localAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"tracks"] completionHandler:^{
        if ([localAsset statusOfValueForKey:@"tracks" error:NULL] != AVKeyValueStatusLoaded)
            return;
        
        NSArray *visualTracks = [localAsset tracksWithMediaCharacteristic:AVMediaCharacteristicVisual];
        NSArray *audibleTracks = [localAsset tracksWithMediaCharacteristic:AVMediaCharacteristicAudible];
        if ([visualTracks count] > 0) {
            NSLog(@"Video available!");
        } else if ([audibleTracks count] > 0) {
            NSLog(@"Audio available!");
        } else {
            NSLog(@"Error loading file!");
        }
    }];
    
    self.blurView.hidden = NO;
    self.processingLabel.hidden = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.activityIndicator startAnimating];
    [self.progressBar setProgress:0.f];
    [self start];
}

- (IBAction)back:(id)sender {
    [self cancel];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)start {
    cancelled = NO;
    
    writingSamples = YES;
    
    AVAsset *localAsset = asset;
    [localAsset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObjects:@"tracks", @"duration", nil] completionHandler:^{
        // Dispatch the setup work to the serialization queue, to ensure this work is serialized with potential cancellation
        dispatch_async(serializationQueue, ^{
            // Since we are doing these things asynchronously, the user may have already cancelled on the main thread.  In that case, simply return from this block
            if (cancelled)
                return;
            
            BOOL success = YES;
            NSError *localError = nil;
            
            success = ([localAsset statusOfValueForKey:@"tracks" error:&localError] == AVKeyValueStatusLoaded);
            if (success) {
                success = ([localAsset statusOfValueForKey:@"duration" error:&localError] == AVKeyValueStatusLoaded);
            }
            
            if (success) {
                timeRange = CMTimeRangeMake(kCMTimeZero, [localAsset duration]);

                // AVAssetWriter does not overwrite files for us, so remove the destination file if it already exists
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *localOutputPath = [outputURL path];
                if ([fm fileExistsAtPath:localOutputPath])
                    success = [fm removeItemAtPath:localOutputPath error:&localError];
            }
            
            // Set up the AVAssetReader and AVAssetWriter, then begin writing samples or flag an error
            if (success) {
                success = [self setUpReaderAndWriterReturningError:&localError];
            }
            if (success) {
                success = [self startReadingAndWritingReturningError:&localError];
            }
            if (!success) {
                [self readingAndWritingDidFinishSuccessfully:success withError:localError];
            }
        });
    }];
}

static inline CGFloat RadiansToDegrees(CGFloat radians) {
  return radians * 180 / M_PI;
};

- (BOOL)setUpReaderAndWriterReturningError:(NSError **)outError {
    BOOL success = YES;
    NSError *localError = nil;
    AVAsset *localAsset = asset;
    NSURL *localOutputURL = outputURL;
    
    // Create asset reader and asset writer
    assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&localError];
    success = (assetReader != nil);
    if (success) {
        assetWriter = [[AVAssetWriter alloc] initWithURL:localOutputURL fileType:AVFileTypeQuickTimeMovie error:&localError];
        success = (assetWriter != nil);
    }

    // Create asset reader outputs and asset writer inputs for the first audio track and first video track of the asset
    if (success) {
        AVAssetTrack *audioTrack = nil, *videoTrack = nil;
        
        // Grab first audio track and first video track, if the asset has them
        NSArray *audioTracks = [localAsset tracksWithMediaType:AVMediaTypeAudio];
        if ([audioTracks count] > 0)
            audioTrack = [audioTracks objectAtIndex:0];
        NSArray *videoTracks = [localAsset tracksWithMediaType:AVMediaTypeVideo];
        if ([videoTracks count] > 0)
            videoTrack = [videoTracks objectAtIndex:0];
        
        if (audioTrack) {
            // Decompress to Linear PCM with the asset reader
            NSDictionary *decompressionAudioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                                        [NSNumber numberWithUnsignedInt:kAudioFormatLinearPCM], AVFormatIDKey,
                                                        nil];
            AVAssetReaderOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:decompressionAudioSettings];
            [assetReader addOutput:output];
            
            AudioChannelLayout stereoChannelLayout = {
                .mChannelLayoutTag = kAudioChannelLayoutTag_Stereo,
                .mChannelBitmap = 0,
                .mNumberChannelDescriptions = 0
            };
            NSData *channelLayoutAsData = [NSData dataWithBytes:&stereoChannelLayout length:offsetof(AudioChannelLayout, mChannelDescriptions)];

            // Compress to 128kbps AAC with the asset writer
            NSDictionary *compressionAudioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                                      [NSNumber numberWithUnsignedInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                                                      [NSNumber numberWithInteger:128000], AVEncoderBitRateKey,
                                                      [NSNumber numberWithInteger:44100], AVSampleRateKey,
                                                      channelLayoutAsData, AVChannelLayoutKey,
                                                      [NSNumber numberWithUnsignedInteger:2], AVNumberOfChannelsKey,
                                                      nil];
            AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:[audioTrack mediaType] outputSettings:compressionAudioSettings];
            input.expectsMediaDataInRealTime = YES;
            [assetWriter addInput:input];
            
            // Create and save an instance of AAPLSampleBufferChannel, which will coordinate the work of reading and writing sample buffers
            audioSampleBufferChannel = [[SampleBufferChannel alloc] initWithAssetReaderOutput:output assetWriterInput:input];
        }
        
        if (videoTrack) {
            // Decompress to ARGB with the asset reader
            NSDictionary *decompressionVideoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                                        [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA], (id)kCVPixelBufferPixelFormatTypeKey,
                                                        [NSDictionary dictionary], (id)kCVPixelBufferIOSurfacePropertiesKey,
                                                        nil];
            AVAssetReaderOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:decompressionVideoSettings];
            [assetReader addOutput:output];
            
            // Get the format description of the track, to fill in attributes of the video stream that we don't want to change
            CMFormatDescriptionRef formatDescription = NULL;
            NSArray *formatDescriptions = [videoTrack formatDescriptions];
            if ([formatDescriptions count] > 0) {
                formatDescription = (__bridge CMFormatDescriptionRef)[formatDescriptions objectAtIndex:0];
            }
            
            // Get video orientation. Original video may be oriented differently then how it was created.
            CGAffineTransform preferredTransform = videoTrack.preferredTransform;
            CGFloat videoAngleInDegree = RadiansToDegrees(atan2(preferredTransform.b, preferredTransform.a));
            
            // Grab track dimensions from format description
            CGSize trackDimensions = {
                .width = 0.0,
                .height = 0.0,
            };
            if (formatDescription) {
                trackDimensions = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, false, false);
            }
            else {
                trackDimensions = [videoTrack naturalSize];
            }
            
            CGFloat h = 0;
            switch ((int)videoAngleInDegree) {
                case 0:
                    orientation = kCGImagePropertyOrientationUp;
                    break;
                case 90:
                    orientation = kCGImagePropertyOrientationLeft;
                    h = trackDimensions.width;
                    trackDimensions.width = trackDimensions.height;
                    trackDimensions.height = h;
                    break;
                case 180:
                    orientation = kCGImagePropertyOrientationDown;
                    break;
                case -90:
                    h = trackDimensions.width;
                    trackDimensions.width = trackDimensions.height;
                    trackDimensions.height = h;
                    orientation = kCGImagePropertyOrientationRight;
                    break;
                
            }
            
            // Set the rendering resolution to the resolution of the input video
            [self.deepAR setRenderingResolutionWithWidth:trackDimensions.width height:trackDimensions.height];

            // Grab clean aperture, pixel aspect ratio from format description
            NSDictionary *compressionSettings = nil;
            if (formatDescription) {
                NSDictionary *cleanAperture = nil;
                NSDictionary *pixelAspectRatio = nil;
                CFDictionaryRef cleanApertureFromCMFormatDescription = (CFDictionaryRef)CMFormatDescriptionGetExtension(formatDescription, kCMFormatDescriptionExtension_CleanAperture);
                if (cleanApertureFromCMFormatDescription) {
                    cleanAperture = [NSDictionary dictionaryWithObjectsAndKeys:
                                     (NSObject*)CFDictionaryGetValue(cleanApertureFromCMFormatDescription, kCMFormatDescriptionKey_CleanApertureWidth), AVVideoCleanApertureWidthKey,
                                     CFDictionaryGetValue(cleanApertureFromCMFormatDescription, kCMFormatDescriptionKey_CleanApertureHeight), AVVideoCleanApertureHeightKey,
                                     CFDictionaryGetValue(cleanApertureFromCMFormatDescription, kCMFormatDescriptionKey_CleanApertureHorizontalOffset), AVVideoCleanApertureHorizontalOffsetKey,
                                     CFDictionaryGetValue(cleanApertureFromCMFormatDescription, kCMFormatDescriptionKey_CleanApertureVerticalOffset), AVVideoCleanApertureVerticalOffsetKey,
                                     nil];
                }
                CFDictionaryRef pixelAspectRatioFromCMFormatDescription = (CFDictionaryRef)CMFormatDescriptionGetExtension(formatDescription, kCMFormatDescriptionExtension_PixelAspectRatio);
                if (pixelAspectRatioFromCMFormatDescription) {
                    pixelAspectRatio = [NSDictionary dictionaryWithObjectsAndKeys:
                                        (NSObject*)CFDictionaryGetValue(pixelAspectRatioFromCMFormatDescription, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing), AVVideoPixelAspectRatioHorizontalSpacingKey,
                                        CFDictionaryGetValue(pixelAspectRatioFromCMFormatDescription, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing), AVVideoPixelAspectRatioVerticalSpacingKey,
                                        nil];
                }
                
                if (cleanAperture || pixelAspectRatio) {
                    NSMutableDictionary *mutableCompressionSettings = [NSMutableDictionary dictionary];
                    if (cleanAperture) {
                        [mutableCompressionSettings setObject:cleanAperture forKey:AVVideoCleanApertureKey];
                    }
                    if (pixelAspectRatio) {
                        [mutableCompressionSettings setObject:pixelAspectRatio forKey:AVVideoPixelAspectRatioKey];
                        compressionSettings = mutableCompressionSettings;
                    }
                }
            }
            
            // Compress to H.264 with the asset writer
            NSMutableDictionary *videoSettings = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                                  AVVideoCodecTypeH264, AVVideoCodecKey,
                                                  [NSNumber numberWithInt:trackDimensions.width], AVVideoWidthKey,
                                                  [NSNumber numberWithInt:trackDimensions.height], AVVideoHeightKey, nil];
            if (compressionSettings) {
                [videoSettings setObject:compressionSettings forKey:AVVideoCompressionPropertiesKey];
            }
            
            AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:[videoTrack mediaType] outputSettings:videoSettings];
            input.expectsMediaDataInRealTime = YES;
            
            NSMutableDictionary *attributes = [[NSMutableDictionary alloc] init];
               [attributes setObject:[NSNumber numberWithUnsignedInt:kCVPixelFormatType_32ARGB] forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
            [attributes setObject:[NSNumber numberWithUnsignedInt:trackDimensions.width] forKey:(NSString*)kCVPixelBufferWidthKey];
            [attributes setObject:[NSNumber numberWithUnsignedInt:trackDimensions.height] forKey:(NSString*)kCVPixelBufferHeightKey];
               
            assetAdapterWriter = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:attributes];
            [assetWriter addInput:input];
            
            // Create and save an instance of AAPLSampleBufferChannel, which will coordinate the work of reading and writing sample buffers
            videoSampleBufferChannel = [[SampleBufferChannel alloc] initWithAssetReaderOutput:output assetWriterInput:input assetAdapterWriter:assetAdapterWriter];
        }
    }
    
    if (outError) {
        *outError = localError;
    }
    
    return success;
}

- (BOOL)startReadingAndWritingReturningError:(NSError **)outError {
    BOOL success = YES;
    NSError *localError = nil;

    // Instruct the asset reader and asset writer to get ready to do work
    success = [assetReader startReading];
    if (!success) {
        localError = [assetReader error];
    }
    if (success) {
        success = [assetWriter startWriting];
        if (!success) {
            localError = [assetWriter error];
        }
    }
    
    if (success) {
        dispatch_group_t dispatchGroup = dispatch_group_create();
        
        // Start a sample-writing session
        [assetWriter startSessionAtSourceTime:timeRange.start];
        
        // Start reading and writing samples
        if (audioSampleBufferChannel) {
            // Only set audio delegate for audio-only assets, else let the video channel drive progress
            id <SampleBufferChannelDelegate> delegate = nil;
            if (!videoSampleBufferChannel) {
                delegate = self;
            }

            dispatch_group_enter(dispatchGroup);
            [audioSampleBufferChannel startWithDelegate:delegate completionHandler:^{
                dispatch_group_leave(dispatchGroup);
            }];
        }
        if (videoSampleBufferChannel) {
            dispatch_group_enter(dispatchGroup);
            [videoSampleBufferChannel startWithDelegate:self completionHandler:^{
                dispatch_group_leave(dispatchGroup);
            }];
        }
        
        // Set up a callback for when the sample writing is finished
        dispatch_group_notify(dispatchGroup, serializationQueue, ^{
            BOOL finalSuccess = YES;
            NSError *finalError = nil;
            
            if (cancelled) {
                [assetReader cancelReading];
                [assetWriter cancelWriting];
            } else {
                if ([assetReader status] == AVAssetReaderStatusFailed) {
                    finalSuccess = NO;
                    finalError = [assetReader error];
                }
                
                if (finalSuccess) {
                    [assetWriter finishWritingWithCompletionHandler:^{
                        if (assetWriter.status == AVAssetWriterStatusFailed) {
                            [self readingAndWritingDidFinishSuccessfully:NO withError:[assetWriter error]];
                        } else {
                            [self readingAndWritingDidFinishSuccessfully:finalSuccess withError:finalError];
                        }
                    }];
                }
            }
        });
    }
    
    if (outError) {
        *outError = localError;
    }
    
    return success;
}

- (void)cancel {
    if (assetWriter) {
        // Dispatch cancellation tasks to the serialization queue to avoid races with setup and teardown
        dispatch_async(serializationQueue, ^{
            [audioSampleBufferChannel cancel];
            [videoSampleBufferChannel cancel];
            cancelled = YES;
        });
    }
}

- (void)readingAndWritingDidFinishSuccessfully:(BOOL)success withError:(NSError *)error {
    if (!success) {
        [assetReader cancelReading];
        [assetWriter cancelWriting];
        NSLog(@"Processing failed with error: %@", error);
    }
    
    // Tear down ivars
    assetReader = nil;
    assetWriter = nil;
    audioSampleBufferChannel = nil;
    videoSampleBufferChannel = nil;
    cancelled = NO;
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self.activityIndicator stopAnimating];
        [self.progressBar setProgress:1.f];
        self.processingLabel.hidden = YES;
        self.blurView.hidden = YES;
        
        AVPlayer* player = [[AVPlayer alloc] initWithURL:outputURL];
        AVPlayerViewController* playerViewController = [[AVPlayerViewController alloc] init];
        playerViewController.player = player;
        [self presentViewController:playerViewController animated:YES completion:^{
            [self back:self];
        }];
    });
}

static double progressOfSampleBufferInTimeRange(CMSampleBufferRef sampleBuffer, CMTimeRange timeRange) {
    CMTime progressTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    progressTime = CMTimeSubtract(progressTime, timeRange.start);
    CMTime sampleDuration = CMSampleBufferGetDuration(sampleBuffer);
    if (CMTIME_IS_NUMERIC(sampleDuration)) {
        progressTime= CMTimeAdd(progressTime, sampleDuration);
    }
    return CMTimeGetSeconds(progressTime) / CMTimeGetSeconds(timeRange.duration);
}

- (void)rotatePixelBuffer:(CVPixelBufferRef*)pixelBuffer {
    size_t width     = CVPixelBufferGetWidth(*pixelBuffer);
    size_t height    = CVPixelBufferGetHeight(*pixelBuffer);
    BOOL landscape   = NO;

    CGImagePropertyOrientation cgOrientation = kCGImagePropertyOrientationUp;

    switch (orientation) {
        case kCGImagePropertyOrientationUp:
            cgOrientation = kCGImagePropertyOrientationUp;
            landscape = NO;
            break;
         
        case kCGImagePropertyOrientationRight:
            cgOrientation = kCGImagePropertyOrientationLeft;
            width     = CVPixelBufferGetHeight(*pixelBuffer);
            height    = CVPixelBufferGetWidth(*pixelBuffer);
            landscape = YES;
            break;
         
        case kCGImagePropertyOrientationLeft:
            cgOrientation = kCGImagePropertyOrientationRight;
            width     = CVPixelBufferGetHeight(*pixelBuffer);
            height    = CVPixelBufferGetWidth(*pixelBuffer);
            landscape = YES;
            break;
         
        default:
            break;
         
    }

    //Portrait, no need to rotate
    if (orientation == kCGImagePropertyOrientationUp) {
        return ;
    }

    @autoreleasepool {
        // roate ciimage
        CIImage *ciImage = [[CIImage imageWithCVPixelBuffer:*pixelBuffer] imageByApplyingCGOrientation:cgOrientation];

        CVPixelBufferRef newPixelBuffer = nil;
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &newPixelBuffer);

        if(!cicontext) {
            cicontext = [CIContext context];
        }
        [cicontext render:ciImage toCVPixelBuffer:newPixelBuffer];
        
        *pixelBuffer = newPixelBuffer;
    };
}

- (void)sampleBufferChannel:(SampleBufferChannel *)sampleBufferChannel didReadSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pixelBuffer = nil;
    
    // Calculate progress (scale of 0.0 to 1.0)
    double progress = progressOfSampleBufferInTimeRange(sampleBuffer, timeRange);
    
    // Grab the pixel buffer from the sample buffer, if possible
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer && (CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID())) {
        pixelBuffer = (CVPixelBufferRef)imageBuffer;
        
        [self.deepAR processFrameAndReturn:pixelBuffer outputBuffer:pixelBuffer mirror:NO orientation:0];
    }
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIImage *uiImage = nil;
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];

        CIContext *temporaryContext = [CIContext contextWithOptions:nil];
        CGImageRef videoImage = [temporaryContext
                                 createCGImage:ciImage
                                 fromRect:CGRectMake(0, 0,
                                                     CVPixelBufferGetWidth(pixelBuffer),
                                                     CVPixelBufferGetHeight(pixelBuffer))];


        uiImage = [UIImage imageWithCGImage:videoImage];

        CGImageRelease(videoImage);
        [self.progressBar setProgress:progress];
        self.previewImage.image = uiImage;
    });
}

- (void)sampleBufferChannel:(SampleBufferChannel *)sampleBufferChannel didReadSampleBuffer:(CMSampleBufferRef)sampleBuffer outputPixelBuffer:(CVPixelBufferRef *)outputPixelBuffer shouldFreePixelBuffer:(BOOL *)shouldFreePixelBuffer {
    
    // Calculate progress (scale of 0.0 to 1.0)
    double progress = progressOfSampleBufferInTimeRange(sampleBuffer, timeRange);
    
    // Grab the pixel buffer from the sample buffer, if possible
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer && (CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID())) {
        *outputPixelBuffer = (CVPixelBufferRef)imageBuffer;
        [self rotatePixelBuffer:outputPixelBuffer];
        *shouldFreePixelBuffer = imageBuffer != *outputPixelBuffer;
        
        // Feed the frame to DeepAR for processing
        [self.deepAR processFrameAndReturn:*outputPixelBuffer outputBuffer:*outputPixelBuffer mirror:NO orientation:0];
    }
    
    // Display the
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIImage *uiImage = nil;
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:*outputPixelBuffer];

        CIContext *temporaryContext = [CIContext contextWithOptions:nil];
        CGImageRef videoImage = [temporaryContext
                                 createCGImage:ciImage
                                 fromRect:CGRectMake(0, 0,
                                                     CVPixelBufferGetWidth(*outputPixelBuffer),
                                                     CVPixelBufferGetHeight(*outputPixelBuffer))];


        uiImage = [UIImage imageWithCGImage:videoImage];

        CGImageRelease(videoImage);
        [self.progressBar setProgress:progress];
        self.previewImage.image = uiImage;
    });
}

@end

@interface SampleBufferChannel ()
- (void)callCompletionHandlerIfNecessary;  // always called on the serialization queue
@end

@implementation SampleBufferChannel

- (id)initWithAssetReaderOutput:(AVAssetReaderOutput *)localAssetReaderOutput assetWriterInput:(AVAssetWriterInput *)localAssetWriterInput {
    self = [super init];
    
    if (self) {
        assetReaderOutput = localAssetReaderOutput;
        assetWriterInput = localAssetWriterInput;
        
        finished = NO;
        NSString *serializationQueueDescription = [NSString stringWithFormat:@"%@ serialization queue", self];
        serializationQueue = dispatch_queue_create([serializationQueueDescription UTF8String], NULL);
    }
    
    return self;
}

- (id)initWithAssetReaderOutput:(AVAssetReaderOutput *)localAssetReaderOutput assetWriterInput:(AVAssetWriterInput *)localAssetWriterInput assetAdapterWriter:(AVAssetWriterInputPixelBufferAdaptor *)loacalAssetAdapterWriter {
    self = [super init];
    
    if (self) {
        assetReaderOutput = localAssetReaderOutput;
        assetWriterInput = localAssetWriterInput;
        assetAdapterWriter = loacalAssetAdapterWriter;
        
        finished = NO;
        NSString *serializationQueueDescription = [NSString stringWithFormat:@"%@ serialization queue", self];
        serializationQueue = dispatch_queue_create([serializationQueueDescription UTF8String], NULL);
    }
    
    return self;
}

- (NSString *)mediaType {
    return [assetReaderOutput mediaType];
}

- (void)startWithDelegate:(id <SampleBufferChannelDelegate>)delegate completionHandler:(dispatch_block_t)localCompletionHandler {
    completionHandler = [localCompletionHandler copy];  // released in -callCompletionHandlerIfNecessary

    [assetWriterInput requestMediaDataWhenReadyOnQueue:serializationQueue usingBlock:^{
        if (finished)
            return;
        
        BOOL completedOrFailed = NO;
        
        // Read samples in a loop as long as the asset writer input is ready
        while ([assetWriterInput isReadyForMoreMediaData] && !completedOrFailed)
        {
            CMSampleBufferRef sampleBuffer = [assetReaderOutput copyNextSampleBuffer];
            BOOL success;
            if (sampleBuffer != NULL) {
                if (assetAdapterWriter != NULL && [delegate respondsToSelector:@selector(sampleBufferChannel:didReadSampleBuffer:outputPixelBuffer:shouldFreePixelBuffer:)]) {
                    CVPixelBufferRef outputBuffer = nil;
                    BOOL shouldFree = NO;
                    
                    [delegate sampleBufferChannel:self didReadSampleBuffer:sampleBuffer outputPixelBuffer:&outputBuffer shouldFreePixelBuffer:&shouldFree];
                    
                    success = [assetAdapterWriter appendPixelBuffer:outputBuffer withPresentationTime:CMSampleBufferGetPresentationTimeStamp(sampleBuffer)];
                    
                    if (shouldFree) {
                        CVPixelBufferRelease(outputBuffer);
                    }
                    
                } else {
                    if ([delegate respondsToSelector:@selector(sampleBufferChannel:didReadSampleBuffer:)]) {
                        [delegate sampleBufferChannel:self didReadSampleBuffer:sampleBuffer];
                    }
                    
                    success = [assetWriterInput appendSampleBuffer:sampleBuffer];
                }
                
                CFRelease(sampleBuffer);
                sampleBuffer = NULL;
                
                completedOrFailed = !success;
            } else {
                completedOrFailed = YES;
            }
        }
        
        if (completedOrFailed) {
            [self callCompletionHandlerIfNecessary];
        }
    }];
}

- (void)cancel {
    dispatch_async(serializationQueue, ^{
        [self callCompletionHandlerIfNecessary];
    });
}

- (void)callCompletionHandlerIfNecessary {
    // Set state to mark that we no longer need to call the completion handler, grab the completion handler, and clear out the ivar
    BOOL oldFinished = finished;
    finished = YES;

    if (oldFinished == NO) {
        [assetWriterInput markAsFinished];  // let the asset writer know that we will not be appending any more samples to this input

        dispatch_block_t localCompletionHandler = completionHandler;
        completionHandler = nil;

        if (localCompletionHandler) {
            localCompletionHandler();
        }
    }
}

@end
