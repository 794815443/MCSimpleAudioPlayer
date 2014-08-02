//
//  MCSimpleAudioPlayer.m
//  MCSimpleAudioPlayer
//
//  Created by Chengyin on 14-7-27.
//  Copyright (c) 2014年 Chengyin. All rights reserved.
//

#import "MCSimpleAudioPlayer.h"
#import "MCAudioSession.h"
#import "MCAudioFileStream.h"
#import "MCAudioOutputQueue.h"
#import "MCAudioBuffer.h"
#import <pthread.h>

@interface MCSimpleAudioPlayer ()<MCAudioFileStreamDelegate>
{
@private
    NSThread *_thread;
    pthread_mutex_t _mutex;
	pthread_cond_t _cond;
    
    MCSAPStatus _status;
    
    unsigned long long _fileSize;
    unsigned long long _offset;
    NSFileHandle *_fileHandler;
    
    UInt32 _bufferSize;
    MCAudioBuffer *_buffer;
    
    MCAudioFileStream *_audioFileStream;
    MCAudioOutputQueue *_audioQueue;
    
    BOOL _started;
    BOOL _pauseRequired;
    BOOL _stopRequired;
    BOOL _pausedByInterrupt;
    
    BOOL _seekRequired;
    NSTimeInterval _seekTime;
    NSTimeInterval _timingOffset;
}
@end

@implementation MCSimpleAudioPlayer
@dynamic status;
@synthesize failed = _failed;
@synthesize fileType = _fileType;
@synthesize filePath = _filePath;
@dynamic isPlayingOrWaiting;
@dynamic duration;
@dynamic progress;

#pragma mark - init & dealloc
- (instancetype)initWithFilePath:(NSString *)filePath fileType:(AudioFileTypeID)fileType
{
    self = [super init];
    if (self)
    {
        _status = -1;
        
        _filePath = filePath;
        _fileType = fileType;
        
        _fileHandler = [NSFileHandle fileHandleForReadingAtPath:_filePath];
        _fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
        if (_fileHandler && _fileSize > 0)
        {
            _buffer = [MCAudioBuffer buffer];
        }
        else
        {
            [_fileHandler closeFile];
            _failed = YES;
        }
    }
    return self;
}

- (void)dealloc
{
    [self cleanup];
    [_fileHandler closeFile];
}

- (void)cleanup
{
    //reset file
    _offset = 0;
    [_fileHandler seekToFileOffset:0];
    
    //deactive audiosession
    [[MCAudioSession sharedInstance] setActive:NO error:NULL];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:MCAudioSessionInterruptionNotification object:nil];
    
    //clean buffer
    [_buffer clean];
    
    //close audioFileStream
    [_audioFileStream close];
    
    //stop audioQueue
    [_audioQueue stop:YES];
    
    //destory mutex & cond
    [self _mutexDestory];
    
    _started = NO;
    _timingOffset = 0;
    _seekTime = 0;
    _seekRequired = NO;
    _pauseRequired = NO;
    _stopRequired = NO;
    
    //reset status
    [self setStatusInternal:MCSAPStatusStopped];
}

#pragma mark - status
- (BOOL)isPlayingOrWaiting
{
    return self.status == MCSAPStatusWaiting || self.status == MCSAPStatusPlaying;
}

- (MCSAPStatus)status
{
    return _status;
}

- (void)setStatusInternal:(MCSAPStatus)status
{
    if (_status == status)
    {
        return;
    }
    
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self didChangeValueForKey:@"status"];
}

#pragma mark - mutex
- (void)_mutexInit
{
    pthread_mutex_init(&_mutex, NULL);
    pthread_cond_init(&_cond, NULL);
}

- (void)_mutexDestory
{
    pthread_mutex_destroy(&_mutex);
    pthread_cond_destroy(&_cond);
}

- (void)_mutexWait
{
    pthread_mutex_lock(&_mutex);
    pthread_cond_wait(&_cond, &_mutex);
	pthread_mutex_unlock(&_mutex);
}

- (void)_mutexSignal
{
    pthread_mutex_lock(&_mutex);
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
}

#pragma mark - thread
- (BOOL)createAudioQueue
{
    if (_audioQueue)
    {
        return YES;
    }
    
    _bufferSize = 0;
    if (_audioFileStream.duration != 0)
    {
        _bufferSize = (0.1 / _audioFileStream.duration) * _audioFileStream.audioDataByteCount;
    }
    if (_bufferSize > 0)
    {
        _audioQueue = [[MCAudioOutputQueue alloc] initWithFormat:_audioFileStream.format bufferSize:_bufferSize macgicCookie:[_audioFileStream fetchMagicCookie]];
        if (!_audioQueue.available)
        {
            _audioQueue = nil;
            return NO;
        }
    }
    return YES;
}

- (void)threadMain
{
    @autoreleasepool
    {
        _failed = YES;
        NSError *error = nil;
        //set audiosession category
        if ([[MCAudioSession sharedInstance] setCategory:kAudioSessionCategory_MediaPlayback error:NULL])
        {
            //active audiosession
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(interruptHandler:) name:MCAudioSessionInterruptionNotification object:nil];
            if ([[MCAudioSession sharedInstance] setActive:YES error:NULL])
            {
                //create audioFileStream
                _audioFileStream = [[MCAudioFileStream alloc] initWithFileType:_fileType fileSize:_fileSize error:&error];
                if (!error)
                {
                    _failed = NO;
                    _audioFileStream.delegate = self;
                }
            }
        }
        
        if (_failed)
        {
            [self cleanup];
            return;
        }
        
        [self setStatusInternal:MCSAPStatusWaiting];
        BOOL isEof = NO;
        while (_offset < _fileSize && self.status != MCSAPStatusStopped && !_failed && _started)
        {
            //read file & parse
            if (!_audioFileStream.readyToProducePackets || [_buffer bufferedSize] < _bufferSize || !_audioQueue)
            {
                NSData *data = [_fileHandler readDataOfLength:1000];
                _offset += [data length];
                if (_offset >= _fileSize)
                {
                    isEof = YES;
                }
                [_audioFileStream parseData:data error:&error];
                if (error)
                {
                    _failed = YES;
                    break;
                }
            }
            
            
            if (_audioFileStream.readyToProducePackets)
            {
                if (![self createAudioQueue])
                {
                    _failed = YES;
                    break;
                }
                
                if (!_audioQueue)
                {
                    continue;
                }
                
                //stop
                if (_stopRequired)
                {
                    _stopRequired = NO;
                    _started = NO;
                    [_audioQueue stop:YES];
                    break;
                }
                
                //pause
                if (_pauseRequired)
                {
                    [self setStatusInternal:MCSAPStatusPaused];
                    [_audioQueue pause];
                    [self _mutexWait];
                    _pauseRequired = NO;
                }
                
                //play
                if ([_buffer bufferedSize] >= _bufferSize)
                {
                    UInt32 packetCount;
                    AudioStreamPacketDescription *desces = NULL;
                    NSData *data = [_buffer dequeueDataWithSize:_bufferSize packetCount:&packetCount descriptions:&desces];
                    if (packetCount != 0)
                    {
                        [self setStatusInternal:MCSAPStatusPlaying];
                        _failed = ![_audioQueue playData:data packetCount:packetCount packetDescriptions:desces isEof:isEof];
                        free(desces);
                        if (_failed)
                        {
                            break;
                        }
                        
                        if (![_buffer hasData] && isEof)
                        {
                            break;
                        }
                    }
                    else
                    {
                        _failed = YES;
                        break;
                        NSLog(@"buffer size too small");
                    }
                }
                
                //seek
                if (_seekRequired)
                {
                    [self setStatusInternal:MCSAPStatusWaiting];
                    
                    _timingOffset = _seekTime - _audioQueue.playedTime;
                    _offset = [_audioFileStream seekToTime:&_seekTime];
                    [_buffer clean];
                    [_fileHandler seekToFileOffset:_offset];
                    _seekRequired = NO;
                    [_audioQueue reset];
                }
            }
        }

        //clean
        [self cleanup];
    }
}

#pragma mark - interrupt
- (void)interruptHandler:(NSNotification *)notification
{
    UInt32 interruptionState = [notification.userInfo[MCAudioSessionInterruptionStateKey] unsignedIntValue];
    
    if (interruptionState == kAudioSessionBeginInterruption)
    {
        _pausedByInterrupt = YES;
        [_audioQueue pause];
        [self setStatusInternal:MCSAPStatusPaused];
        
    }
    else if (interruptionState == kAudioSessionEndInterruption)
    {
        AudioSessionInterruptionType interruptionType = [notification.userInfo[MCAudioSessionInterruptionTypeKey] unsignedIntValue];
        if (interruptionType == kAudioSessionInterruptionType_ShouldResume)
        {
            if (self.status == MCSAPStatusPaused && _pausedByInterrupt)
            {
                if ([[MCAudioSession sharedInstance] setActive:YES error:NULL])
                {
                    [self play];
                }
            }
        }
    }
}

#pragma mark - parser
- (void)audioFileStream:(MCAudioFileStream *)audioFileStream audioDataParsed:(NSArray *)audioData
{
    [_buffer enqueueFromDataArray:audioData];
}

#pragma mark - progress
- (NSTimeInterval)progress
{
    if (_seekRequired)
    {
        return _seekTime;
    }
    return _timingOffset + _audioQueue.playedTime;
}

- (void)setProgress:(NSTimeInterval)progress
{
    _seekRequired = YES;
    _seekTime = progress;
}

- (NSTimeInterval)duration
{
    return _audioFileStream.duration;
}

#pragma mark - method
- (void)play
{
    if (!_started)
    {
        _started = YES;
        [self _mutexInit];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
        [_thread start];
    }
    else
    {
        if (_status == MCSAPStatusPaused || _pauseRequired)
        {
            _pausedByInterrupt = NO;
            _pauseRequired = NO;
            if ([[MCAudioSession sharedInstance] setActive:YES error:NULL])
            {
                [[MCAudioSession sharedInstance] setCategory:kAudioSessionCategory_MediaPlayback error:NULL];
                [self _resume];
            }
        }
    }
}

- (void)_resume
{
    [_audioQueue resume];
    [self _mutexSignal];
}

- (void)pause
{
    if (self.isPlayingOrWaiting)
    {
        _pauseRequired = YES;
    }
}

- (void)stop
{
    _stopRequired = YES;
    [self _mutexSignal];
}
@end
