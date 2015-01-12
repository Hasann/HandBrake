/*  HBPreviewGenerator.m $

 This file is part of the HandBrake source code.
 Homepage: <http://handbrake.fr/>.
 It may be used under the terms of the GNU General Public License. */
//

#import "HBPreviewGenerator.h"
#import "HBUtilities.h"
#import "Controller.h"

#import "HBCore.h"
#import "HBJob.h"

typedef enum EncodeState : NSUInteger {
    EncodeStateIdle,
    EncodeStateWorking,
    EncodeStateCancelled,
} EncodeState;

@interface HBPreviewGenerator ()

@property (nonatomic, readonly, retain) NSMutableDictionary *picturePreviews;
@property (nonatomic, readonly) NSUInteger imagesCount;
@property (nonatomic, readonly) HBCore *scanCore;
@property (nonatomic, readonly) HBJob *job;

@property (nonatomic) HBCore *core;
@property (nonatomic, getter=isCancelled) BOOL cancelled;


@property (nonatomic, retain) NSURL *fileURL;

@end

@implementation HBPreviewGenerator

- (instancetype)initWithCore:(HBCore *)core job:(HBJob *)job
{
    self = [super init];
    if (self)
    {
        _scanCore = core;
        _job = job;
        _picturePreviews = [[NSMutableDictionary alloc] init];
        _imagesCount = [[[NSUserDefaults standardUserDefaults] objectForKey:@"PreviewsNumber"] intValue];
    }
    return self;
}

#pragma mark -
#pragma mark Preview images

/**
 * Returns the picture preview at the specified index
 *
 * @param index picture index in title.
 */
- (NSImage *) imageAtIndex: (NSUInteger) index shouldCache: (BOOL) cache
{
    if (index >= self.imagesCount)
        return nil;

    // The preview for the specified index may not currently exist, so this method
    // generates it if necessary.
    NSImage *theImage = [self.picturePreviews objectForKey:@(index)];

    if (!theImage)
    {
        HBFilters *filters = self.job.filters;
        BOOL deinterlace = (filters.deinterlace && !filters.useDecomb) || (filters.decomb && filters.useDecomb);

        theImage = [HBPreviewGenerator makeImageForPicture:index
                                                     libhb:self.scanCore.hb_handle
                                                   picture:self.job.picture
                                               deinterlace:deinterlace];
        if (cache && theImage)
            [self.picturePreviews setObject:theImage forKey:@(index)];
    }

    return theImage;
}

/**
 * Purges all images from the cache. The next call to imageAtIndex: will cause a new
 * image to be generated.
 */
- (void) purgeImageCache
{
    [self.picturePreviews removeAllObjects];
}

/** 
 * This function converts an image created by libhb (specified via pictureIndex) into
 * an NSImage suitable for the GUI code to use. If removeBorders is YES,
 * makeImageForPicture crops the image generated by libhb stripping off the gray
 * border around the content. This is the low-level method that generates the image.
 * -imageForPicture calls this function whenever it can't find an image in its cache.
 *
 * @param pictureIndex Index in title.
 * @param handle Handle to hb_handle_t.
 * @param title Handle to hb_title_t of desired title.
 * @param deinterlace Whether the preview image must be deinterlaced or not.
 */
+ (NSImage *) makeImageForPicture: (NSUInteger) pictureIndex
                            libhb: (hb_handle_t *) handle
                          picture: (HBPicture *) picture
                      deinterlace: (BOOL) deinterlace
{
    NSImage *img = nil;

    hb_geometry_settings_t geo;
    memset(&geo, 0, sizeof(geo));
    geo.geometry.width = picture.width;
    geo.geometry.height = picture.height;
    // HBPreviewController will scale the image later,
    // ignore the par.
    geo.geometry.par.num = 1;
    geo.geometry.par.den = 1;
    int crop[4] = {picture.cropTop, picture.cropBottom, picture.cropLeft, picture.cropRight};
    memcpy(geo.crop, crop, sizeof(int[4]));

    hb_image_t *image;
    image = hb_get_preview2(handle, picture.title.hb_title->index, (int)pictureIndex, &geo, deinterlace);

    if (image)
    {
        // Create an NSBitmapImageRep and copy the libhb image into it, converting it from
        // libhb's format to one suitable for NSImage.

        // The image data returned by hb_get_preview2 is 4 bytes per pixel, BGRA format.
        // Alpha is ignored.
        NSBitmapImageRep *imgrep = [[[NSBitmapImageRep alloc]
                                     initWithBitmapDataPlanes:nil
                                     pixelsWide:image->width
                                     pixelsHigh:image->height
                                     bitsPerSample:8
                                     samplesPerPixel:3   // ignore alpha
                                     hasAlpha:NO
                                     isPlanar:NO
                                     colorSpaceName:NSCalibratedRGBColorSpace
                                     bitmapFormat:NSAlphaFirstBitmapFormat
                                     bytesPerRow:image->width * 4
                                     bitsPerPixel:32] autorelease];

        UInt8 *src_line = image->data;
        UInt32 *dst = (UInt32 *)[imgrep bitmapData];
        for (int r = 0; r < image->height; r++)
        {
            UInt32 *src = (UInt32 *)src_line;
            for (int c = 0; c < image->width; c++)
            {
#if TARGET_RT_LITTLE_ENDIAN
                *dst++ = Endian32_Swap(*src++);
#else
                *dst++ = *src++;
#endif
            }
            src_line += image->plane[0].stride;
        }

        img = [[[NSImage alloc] initWithSize: NSMakeSize(image->width, image->height)] autorelease];
        [img addRepresentation:imgrep];
    }

    hb_image_close(&image);

    return img;
}

#pragma mark -
#pragma mark Preview movie

+ (NSURL *) generateFileURLForType:(NSString *) type
{
    NSString *previewDirectory = [NSString stringWithFormat:@"%@/Previews/%d", [HBUtilities appSupportPath], getpid()];

    if (![[NSFileManager defaultManager] fileExistsAtPath:previewDirectory])
    {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:previewDirectory
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil])
            return nil;
    }

    return [[NSURL fileURLWithPath:previewDirectory]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"preview_temp.%@", type]];
}

/**
 * This function start the encode of a movie preview, the delegate will be
 * called with the updated the progress info and the fileURL.
 *
 * @param index picture index in title.
 * @param duration the duration in seconds of the preview movie.
 */
- (BOOL) createMovieAsyncWithImageIndex: (NSUInteger) index andDuration: (NSUInteger) duration;
{
    /* return if an encoding if already started */
    if (self.core || index >= self.imagesCount)
        return NO;

    hb_job_t *job = self.job.hb_job;

    /* Generate the file url and directories. */
    if (job->mux & HB_MUX_MASK_MP4)
    {
        /* we use .m4v for our mp4 files so that ac3 and chapters in mp4 will play properly */
        self.fileURL = [HBPreviewGenerator generateFileURLForType:@"m4v"];
    }
    else if (job->mux & HB_MUX_MASK_MKV)
    {
        self.fileURL = [HBPreviewGenerator generateFileURLForType:@"mkv"];
    }

    /* return if we couldn't get the fileURL */
    if (!self.fileURL)
        return NO;

    /* See if there is an existing preview file, if so, delete it */
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self.fileURL path]])
    {
        [[NSFileManager defaultManager] removeItemAtPath:[self.fileURL path] error:NULL];
    }

    /* We now direct our preview encode to fileURL path */
    hb_job_set_file(job, [[self.fileURL path] UTF8String]);

    /* We use our advance pref to determine how many previews to scan */
    job->start_at_preview = (int)index + 1;
    job->seek_points = (int)self.imagesCount;
    job->pts_to_stop = duration * 90000LL;

    /* lets go ahead and send it off to libhb
     * Note: unlike a full encode, we only send 1 pass regardless if the final encode calls for 2 passes.
     * this should suffice for a fairly accurate short preview and cuts our preview generation time in half.
     * However we also need to take into account the indepth scan for subtitles.
     */

    int loggingLevel = [[[NSUserDefaults standardUserDefaults] objectForKey:@"LoggingLevel"] intValue];
    self.core = [[[HBCore alloc] initWithLoggingLevel:loggingLevel] autorelease];
    self.core.name = @"PreviewCore";


    /* Go ahead and perform the actual encoding preview scan */
    hb_add(self.core.hb_handle, job);

    /* we need to clean up the various lists after the job(s) have been set  */
    hb_job_close(&job);

    [self registerCoreNotifications];
    self.cancelled = NO;

    /* start the actual encode */
    [self.core start];

    return YES;
}

/**
 * Cancels the encoding process
 */
- (void) cancel
{
    if (self.core)
    {
        if (self.core.state == HBStateWorking || self.core.state == HBStatePaused)
        {
            [self.core stop];
            self.cancelled = YES;
        }
    }
}

/**
 *  Registers for notifications from HBCore.
 */
- (void) registerCoreNotifications
{
    NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];

    [[NSNotificationCenter defaultCenter] addObserverForName:HBCoreWorkingNotification object:self.core queue:mainQueue usingBlock:^(NSNotification *note) {
        hb_state_t s = *(self.core.hb_state);

        NSMutableString *info = [NSMutableString stringWithFormat: @"Encoding preview:  %.2f %%", 100.0 * s.param.working.progress];

        if (s.param.working.seconds > -1)
        {
            [info appendFormat:@" (%.2f fps, avg %.2f fps, ETA %02dh%02dm%02ds)",
             s.param.working.rate_cur, s.param.working.rate_avg, s.param.working.hours,
             s.param.working.minutes, s.param.working.seconds];
        }

        double progress = 100.0 * s.param.working.progress;

        [self.delegate updateProgress:progress info:info];
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:HBCoreMuxingNotification object:self.core queue:mainQueue usingBlock:^(NSNotification *note) {
        [self.delegate updateProgress:100.0 info:@"Muxing Preview…"];
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:HBCoreWorkDoneNotification object:self.core queue:mainQueue usingBlock:^(NSNotification *note) {
        [self.core stop];
        self.core = nil;

        /* Encode done, call the delegate and close libhb handle */
        if (!self.isCancelled)
        {
            [self.delegate didCreateMovieAtURL:self.fileURL];
        }
        else
        {
            [self.delegate didCancelMovieCreation];
        }

        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }];
}

#pragma mark -

- (void) dealloc
{
    [self.core stop];
    self.core = nil;

    [_fileURL release];
    _fileURL = nil;
    [_picturePreviews release];
    _picturePreviews = nil;

    [super dealloc];
}

@end
