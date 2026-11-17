import {
  BinaryMessenger,
  EventChannel,
  EventSink,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler,
  SurfaceTextureEntry,
  TextureRegistry
} from '@ohos/flutter_ohos';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  extractMethodArg,
  stringRecordFromDynamicObject
} from './OhosDynamicBridge';

const METHOD_CHANNEL_NAME: string = 'com.pilipala.marcomovie/ohos_avplayer';
const EVENT_CHANNEL_PREFIX: string = 'com.pilipala.marcomovie/ohos_avplayer/events/';

class AvPlayerEventStreamHandler implements StreamHandler {
  private sink: EventSink | null = null;
  private pendingEvents: Array<Record<string, Object>> = [];

  onListen(_args: ESObject, events: EventSink): void {
    this.sink = events;
    if (this.pendingEvents.length > 0) {
      const queued: Array<Record<string, Object>> = this.pendingEvents;
      this.pendingEvents = [];
      for (let i = 0; i < queued.length; i++) {
        this.sink.success(queued[i]);
      }
    }
  }

  onCancel(_args: ESObject): void {
    this.sink = null;
  }

  emit(payload: Record<string, Object>): void {
    if (this.sink !== null) {
      this.sink.success(payload);
    } else if (this.pendingEvents.length < 32) {
      this.pendingEvents.push(payload);
    }
  }

  clear(): void {
    this.sink = null;
    this.pendingEvents = [];
  }
}

class PlayerSession {
  readonly playerId: number;
  readonly textureId: number;
  readonly surfaceId: string;
  readonly surfaceEntry: SurfaceTextureEntry;
  readonly avPlayer: media.AVPlayer;
  readonly eventChannel: EventChannel;
  readonly streamHandler: AvPlayerEventStreamHandler;

  playing: boolean = false;
  buffering: boolean = false;
  completed: boolean = false;
  positionMs: number = 0;
  durationMs: number = 0;
  bufferedMs: number = 0;
  bufferingPercent: number = 100;
  bitrate: number = 0;
  videoWidth: number = 0;
  videoHeight: number = 0;
  pendingStartPositionMs: number = 0;
  pendingAutoPlay: boolean = true;
  pendingSpeed: media.PlaybackSpeed | null = null;
  pendingVolume: number | null = null;
  disposed: boolean = false;

  constructor(
    playerId: number,
    textureId: number,
    surfaceId: string,
    surfaceEntry: SurfaceTextureEntry,
    avPlayer: media.AVPlayer,
    eventChannel: EventChannel,
    streamHandler: AvPlayerEventStreamHandler
  ) {
    this.playerId = playerId;
    this.textureId = textureId;
    this.surfaceId = surfaceId;
    this.surfaceEntry = surfaceEntry;
    this.avPlayer = avPlayer;
    this.eventChannel = eventChannel;
    this.streamHandler = streamHandler;
  }
}

export class OhosAvPlayerPlugin implements FlutterPlugin, MethodCallHandler {
  private methodChannel: MethodChannel | null = null;
  private binaryMessenger: BinaryMessenger | null = null;
  private textureRegistry: TextureRegistry | null = null;
  private sessions: Map<number, PlayerSession> = new Map();
  private nextPlayerId: number = 0;

  getUniqueClassName(): string {
    return 'OhosAvPlayerPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.binaryMessenger = binding.getBinaryMessenger();
    this.textureRegistry = binding.getTextureRegistry();
    this.methodChannel = new MethodChannel(this.binaryMessenger, METHOD_CHANNEL_NAME);
    this.methodChannel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    if (this.methodChannel !== null) {
      this.methodChannel.setMethodCallHandler(null);
      this.methodChannel = null;
    }
    const ids: Array<number> = Array.from(this.sessions.keys());
    for (let i = 0; i < ids.length; i++) {
      this.disposeSession(ids[i]);
    }
    this.binaryMessenger = null;
    this.textureRegistry = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.dispatchAsync(call, result);
  }

  private async dispatchAsync(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      switch (call.method) {
        case 'create': {
          result.success(await this.handleCreate());
          return;
        }
        case 'open': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          const url: string = String(this.getArg(call, 'url') ?? '');
          const rawHeaders: ESObject = this.getArg(call, 'headers');
          const startPositionMs: number = Math.max(0, Math.trunc(Number(this.getArg(call, 'startPositionMs') ?? 0)));
          const rawAutoPlay: ESObject = this.getArg(call, 'autoPlay');
          const autoPlay: boolean = rawAutoPlay === undefined || rawAutoPlay === null ? true : Boolean(rawAutoPlay);
          const rawPreferredHdr: ESObject = this.getArg(call, 'preferredHdr');
          const preferredHdr: boolean =
            rawPreferredHdr === undefined || rawPreferredHdr === null ? true : Boolean(rawPreferredHdr);
          const rawBufferSec: ESObject = this.getArg(call, 'preferredBufferDuration');
          const preferredBufferDuration: number =
            rawBufferSec === undefined || rawBufferSec === null
              ? 20
              : Math.min(20, Math.max(1, Math.trunc(Number(rawBufferSec))));
          result.success(
            await this.handleOpen(
              playerId,
              url,
              rawHeaders,
              startPositionMs,
              autoPlay,
              preferredHdr,
              preferredBufferDuration
            )
          );
          return;
        }
        case 'play': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          result.success(await this.handlePlay(playerId));
          return;
        }
        case 'pause': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          result.success(await this.handlePause(playerId));
          return;
        }
        case 'stop': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          result.success(await this.handleStop(playerId));
          return;
        }
        case 'seek': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          const positionMs: number = Math.max(0, Math.trunc(Number(this.getArg(call, 'positionMs') ?? 0)));
          result.success(await this.handleSeek(playerId, positionMs));
          return;
        }
        case 'setRate': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          const rate: number = Number(this.getArg(call, 'rate') ?? 1.0);
          result.success(await this.handleSetRate(playerId, rate));
          return;
        }
        case 'setVolume': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          const volume: number = Number(this.getArg(call, 'volume') ?? 1.0);
          result.success(await this.handleSetVolume(playerId, volume));
          return;
        }
        case 'getTracks': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          result.success(await this.handleGetTracks(playerId));
          return;
        }
        case 'selectTrack': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          const index: number = Math.trunc(Number(this.getArg(call, 'index') ?? 0));
          result.success(await this.handleSelectTrack(playerId, index));
          return;
        }
        case 'deselectTrack': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          const index: number = Math.trunc(Number(this.getArg(call, 'index') ?? 0));
          result.success(await this.handleDeselectTrack(playerId, index));
          return;
        }
        case 'dispose': {
          const playerId: number = Math.trunc(Number(this.getArg(call, 'playerId') ?? 0));
          result.success(await this.disposeSession(playerId));
          return;
        }
        default: {
          result.notImplemented();
          return;
        }
      }
    } catch (err) {
      const error = err as BusinessError;
      result.error(
        String(error?.code ?? 'OHOS_AVPLAYER_ERROR'),
        String(error?.message ?? String(err)),
        null
      );
    }
  }

  private getArg(call: MethodCall, key: string): ESObject {
    return extractMethodArg(call, key);
  }

  private toHeaderRecord(rawHeaders: ESObject): Record<string, string> {
    return stringRecordFromDynamicObject(rawHeaders);
  }

  private requireSession(playerId: number): PlayerSession {
    const session: PlayerSession | undefined = this.sessions.get(playerId);
    if (session === undefined || session.disposed) {
      throw new Error('Unknown or disposed OhosAvPlayer session: ' + String(playerId));
    }
    return session;
  }

  private isPlayableState(state: string): boolean {
    return state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed';
  }

  private mapPlaybackSpeed(rate: number): media.PlaybackSpeed {
    if (rate <= 0.625) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    }
    if (rate <= 0.875) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (rate <= 1.125) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (rate <= 1.375) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (rate <= 1.625) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    }
    if (rate <= 1.875) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }

  private emitState(session: PlayerSession): void {
    if (session.disposed) {
      return;
    }
    const payload: Record<string, Object> = {
      'type': 'state',
      'playing': session.playing,
      'buffering': session.buffering,
      'completed': session.completed
    };
    session.streamHandler.emit(payload);
  }

  private emitPosition(session: PlayerSession): void {
    if (session.disposed) {
      return;
    }
    const payload: Record<string, Object> = {
      'type': 'position',
      'positionMs': Math.max(0, Math.trunc(session.positionMs)),
      'durationMs': Math.max(0, Math.trunc(session.durationMs)),
      'bufferedMs': Math.max(0, Math.trunc(session.bufferedMs))
    };
    session.streamHandler.emit(payload);
  }

  private emitVideoSize(session: PlayerSession, width: number, height: number): void {
    if (session.disposed) {
      return;
    }
    const cleanWidth: number = Math.max(0, Math.trunc(width));
    const cleanHeight: number = Math.max(0, Math.trunc(height));
    session.videoWidth = cleanWidth;
    session.videoHeight = cleanHeight;
    const payload: Record<string, Object> = {
      'type': 'videoSize',
      'width': cleanWidth,
      'height': cleanHeight,
      'bitrate': Math.max(0, Math.trunc(session.bitrate))
    };
    session.streamHandler.emit(payload);
  }

  private emitBufferingPercent(session: PlayerSession, percent: number): void {
    if (session.disposed) {
      return;
    }
    const clamped: number = Math.min(100, Math.max(0, Math.trunc(percent)));
    session.bufferingPercent = clamped;
    const payload: Record<string, Object> = {
      'type': 'bufferingPercent',
      'percent': clamped,
      'bitrate': Math.max(0, Math.trunc(session.bitrate)),
      'width': session.videoWidth,
      'height': session.videoHeight
    };
    session.streamHandler.emit(payload);
  }

  private emitError(session: PlayerSession, code: number, message: string): void {
    if (session.disposed) {
      return;
    }
    const payload: Record<string, Object> = {
      'type': 'error',
      'code': Math.trunc(code),
      'message': message
    };
    session.streamHandler.emit(payload);
  }

  private async handleCreate(): Promise<Record<string, number>> {
    if (this.textureRegistry === null || this.binaryMessenger === null) {
      throw new Error('OhosAvPlayerPlugin is not attached to a FlutterEngine');
    }
    const playerId: number = ++this.nextPlayerId;
    const textureId: number = Math.trunc(Number(this.textureRegistry.getTextureId()));
    const surfaceEntry: SurfaceTextureEntry = this.textureRegistry.registerTexture(textureId);
    const surfaceId: string = String(surfaceEntry.getSurfaceId());

    const avPlayer: media.AVPlayer = await media.createAVPlayer();
    const streamHandler: AvPlayerEventStreamHandler = new AvPlayerEventStreamHandler();
    const eventChannel: EventChannel = new EventChannel(
      this.binaryMessenger,
      EVENT_CHANNEL_PREFIX + String(playerId)
    );
    eventChannel.setStreamHandler(streamHandler);

    const session: PlayerSession = new PlayerSession(
      playerId,
      textureId,
      surfaceId,
      surfaceEntry,
      avPlayer,
      eventChannel,
      streamHandler
    );
    this.wireAvPlayerCallbacks(session);
    this.sessions.set(playerId, session);

    const created: Record<string, number> = {
      'playerId': playerId,
      'textureId': textureId
    };
    return created;
  }

  private wireAvPlayerCallbacks(session: PlayerSession): void {
    const avPlayer: media.AVPlayer = session.avPlayer;

    avPlayer.on('stateChange', async (state: string, _reason: media.StateChangeReason) => {
      if (session.disposed) {
        return;
      }
      switch (state) {
        case 'initialized': {
          avPlayer.surfaceId = session.surfaceId;
          try {
            await avPlayer.prepare();
          } catch (err) {
            const error = err as BusinessError;
            session.playing = false;
            session.buffering = false;
            this.emitState(session);
            this.emitError(
              session,
              Number(error?.code ?? -1),
              String(error?.message ?? 'Failed to prepare AVPlayer')
            );
          }
          break;
        }
        case 'prepared': {
          session.buffering = false;
          session.completed = false;
          if (avPlayer.duration > 0) {
            session.durationMs = Math.trunc(avPlayer.duration);
          }
          if (avPlayer.width > 0 && avPlayer.height > 0) {
            this.emitVideoSize(session, avPlayer.width, avPlayer.height);
          }
          if (session.pendingVolume !== null) {
            avPlayer.setVolume(session.pendingVolume);
          }
          if (session.pendingSpeed !== null) {
            avPlayer.setSpeed(session.pendingSpeed);
          }
          if (session.pendingStartPositionMs > 0) {
            const targetPos: number = session.pendingStartPositionMs;
            session.pendingStartPositionMs = 0;
            session.positionMs = targetPos;
            avPlayer.seek(targetPos, media.SeekMode.SEEK_CLOSEST);
          } else if (avPlayer.currentTime >= 0) {
            session.positionMs = Math.trunc(avPlayer.currentTime);
          }
          this.emitPosition(session);
          this.handleGetTracks(session.playerId).then((tracks: Array<Record<string, Object>>) => {
            if (!session.disposed && tracks.length > 0) {
              const tracksPayload: Record<string, Object> = {
                'type': 'tracks',
                'tracks': tracks
              };
              session.streamHandler.emit(tracksPayload);
            }
          }).catch(() => {});
          if (session.pendingAutoPlay) {
            try {
              await avPlayer.play();
            } catch (err) {
              const error = err as BusinessError;
              this.emitError(
                session,
                Number(error?.code ?? -1),
                String(error?.message ?? 'Failed to start AVPlayer')
              );
            }
          } else {
            session.playing = false;
            this.emitState(session);
          }
          break;
        }
        case 'playing': {
          session.playing = true;
          session.buffering = false;
          session.completed = false;
          this.emitState(session);
          break;
        }
        case 'paused': {
          session.playing = false;
          session.buffering = false;
          this.emitState(session);
          break;
        }
        case 'completed': {
          session.playing = false;
          session.buffering = false;
          session.completed = true;
          if (session.durationMs > 0) {
            session.positionMs = session.durationMs;
            this.emitPosition(session);
          }
          this.emitState(session);
          break;
        }
        case 'stopped':
        case 'idle': {
          session.playing = false;
          session.buffering = false;
          session.completed = false;
          this.emitState(session);
          break;
        }
        case 'error': {
          session.playing = false;
          session.buffering = false;
          this.emitState(session);
          break;
        }
        default: {
          break;
        }
      }
    });

    avPlayer.on('timeUpdate', (timeMs: number) => {
      if (session.disposed) {
        return;
      }
      session.positionMs = Math.max(0, Math.trunc(timeMs));
      if (avPlayer.duration > 0) {
        session.durationMs = Math.max(0, Math.trunc(avPlayer.duration));
      }
      if (session.bufferedMs < session.positionMs) {
        session.bufferedMs = session.positionMs;
      }
      this.emitPosition(session);
    });

    avPlayer.on('durationUpdate', (durationMs: number) => {
      if (session.disposed) {
        return;
      }
      session.durationMs = Math.max(0, Math.trunc(durationMs));
      this.emitPosition(session);
    });

    avPlayer.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (session.disposed) {
        return;
      }
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        session.buffering = true;
        this.emitBufferingPercent(session, 0);
        this.emitState(session);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        session.buffering = false;
        this.emitBufferingPercent(session, 100);
        this.emitState(session);
      } else if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        session.bufferedMs = Math.max(
          session.positionMs,
          session.positionMs + Math.max(0, Math.trunc(value))
        );
        this.emitPosition(session);
      } else if (infoType === media.BufferingInfoType.BUFFERING_PERCENT) {
        const pct: number = Math.min(100, Math.max(0, value));
        this.emitBufferingPercent(session, pct);
        if (session.durationMs > 0) {
          session.bufferedMs = Math.max(
            session.bufferedMs,
            Math.trunc((session.durationMs * pct) / 100)
          );
          this.emitPosition(session);
        }
      }
    });

    avPlayer.on('videoSizeChange', (width: number, height: number) => {
      if (session.disposed) {
        return;
      }
      this.emitVideoSize(session, width, height);
    });

    avPlayer.on('error', (err: BusinessError) => {
      if (session.disposed) {
        return;
      }
      session.playing = false;
      session.buffering = false;
      this.emitState(session);
      this.emitError(
        session,
        Number(err?.code ?? -1),
        String(err?.message ?? 'AVPlayer playback error')
      );
    });
  }

  private isNetworkStreamUrl(url: string): boolean {
    const colonIdx: number = url.indexOf(':');
    if (colonIdx <= 0) {
      return false;
    }
    const scheme: string = url.substring(0, colonIdx).toLowerCase();
    return scheme === 'http' || scheme === 'https' || scheme === 'rtmp' || scheme === 'rtsp';
  }

  private async handleOpen(
    playerId: number,
    url: string,
    rawHeaders: ESObject,
    startPositionMs: number,
    autoPlay: boolean,
    preferredHdr: boolean = true,
    preferredBufferDuration: number = 20
  ): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    const trimmedUrl: string = url.trim();
    if (trimmedUrl.length === 0) {
      throw new Error('OhosAvPlayer open requires a non-empty url');
    }
    if (session.avPlayer.state !== 'idle') {
      await session.avPlayer.reset();
    }
    session.playing = false;
    session.buffering = true;
    session.completed = false;
    session.positionMs = startPositionMs;
    session.durationMs = 0;
    session.bufferedMs = startPositionMs;
    session.bufferingPercent = 0;
    session.bitrate = 0;
    session.videoWidth = 0;
    session.videoHeight = 0;
    session.pendingStartPositionMs = startPositionMs;
    session.pendingAutoPlay = autoPlay;
    this.emitState(session);

    const headers: Record<string, string> = this.toHeaderRecord(rawHeaders);
    const headerKeys: Array<string> = Object.keys(headers);
    if (headerKeys.length > 0 || this.isNetworkStreamUrl(trimmedUrl)) {
      try {
        const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(trimmedUrl, headers);
        const clampedBufferSec: number = Math.min(20, Math.max(1, Math.trunc(preferredBufferDuration)));
        const playbackStrategy: media.PlaybackStrategy = {
          preferredBufferDuration: clampedBufferSec,
          preferredHdr: preferredHdr
        };
        await session.avPlayer.setMediaSource(mediaSource, playbackStrategy);
      } catch (_err) {
        session.avPlayer.url = trimmedUrl;
      }
    } else {
      session.avPlayer.url = trimmedUrl;
    }
    return true;
  }

  private async handlePlay(playerId: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    session.pendingAutoPlay = true;
    const state: string = session.avPlayer.state;
    if (state === 'prepared' || state === 'paused' || state === 'completed') {
      await session.avPlayer.play();
    }
    return true;
  }

  private async handlePause(playerId: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    session.pendingAutoPlay = false;
    if (session.avPlayer.state === 'playing') {
      await session.avPlayer.pause();
    }
    return true;
  }

  private async handleStop(playerId: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    session.pendingAutoPlay = false;
    if (this.isPlayableState(session.avPlayer.state)) {
      await session.avPlayer.stop();
    }
    return true;
  }

  private async handleSeek(playerId: number, positionMs: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    if (this.isPlayableState(session.avPlayer.state)) {
      session.positionMs = positionMs;
      session.avPlayer.seek(positionMs, media.SeekMode.SEEK_CLOSEST);
    } else {
      session.pendingStartPositionMs = positionMs;
    }
    return true;
  }

  private async handleSetRate(playerId: number, rate: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    const speed: media.PlaybackSpeed = this.mapPlaybackSpeed(rate);
    session.pendingSpeed = speed;
    if (this.isPlayableState(session.avPlayer.state)) {
      session.avPlayer.setSpeed(speed);
    }
    return true;
  }

  private async handleSetVolume(playerId: number, volume: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    const normalized: number = volume > 1.0
      ? Math.min(1.0, Math.max(0.0, volume / 100.0))
      : Math.min(1.0, Math.max(0.0, volume));
    session.pendingVolume = normalized;
    if (this.isPlayableState(session.avPlayer.state)) {
      session.avPlayer.setVolume(normalized);
    }
    return true;
  }

  private async handleGetTracks(playerId: number): Promise<Array<Record<string, Object>>> {
    const session: PlayerSession = this.requireSession(playerId);
    const tracks: Array<Record<string, Object>> = [];
    if (!this.isPlayableState(session.avPlayer.state)) {
      return tracks;
    }
    const descriptions: Array<media.MediaDescription> = await session.avPlayer.getTrackDescription();
    for (let i = 0; i < descriptions.length; i++) {
      const desc: media.MediaDescription = descriptions[i];
      const rawIndex: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX];
      const rawType: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE];
      const rawMime: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_CODEC_MIME];
      const rawLang: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_LANGUAGE];
      const rawBitrate: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_BITRATE];
      const rawWidth: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_WIDTH];
      const rawHeight: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_HEIGHT];
      const rawName: Object | undefined = desc[media.MediaDescriptionKey.MD_KEY_TRACK_NAME];
      const trackTypeInt: number = Math.trunc(Number(rawType ?? -1));
      const trackBitrate: number = Math.trunc(Number(rawBitrate ?? 0));
      const trackWidth: number = Math.trunc(Number(rawWidth ?? 0));
      const trackHeight: number = Math.trunc(Number(rawHeight ?? 0));
      if (trackTypeInt === 1 && trackBitrate > 0) {
        session.bitrate = trackBitrate;
      }
      if (trackTypeInt === 1 && trackWidth > 0 && trackHeight > 0 && session.videoWidth === 0) {
        this.emitVideoSize(session, trackWidth, trackHeight);
      }
      const item: Record<string, Object> = {
        'index': Math.trunc(Number(rawIndex ?? i)),
        'trackType': trackTypeInt,
        'codec': String(rawMime ?? ''),
        'mimeType': String(rawMime ?? ''),
        'language': String(rawLang ?? ''),
        'bitrate': trackBitrate,
        'width': trackWidth,
        'height': trackHeight,
        'title': String(rawName ?? '')
      };
      tracks.push(item);
    }
    return tracks;
  }

  private async handleSelectTrack(playerId: number, index: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    if (this.isPlayableState(session.avPlayer.state)) {
      await session.avPlayer.selectTrack(index);
      return true;
    }
    return false;
  }

  private async handleDeselectTrack(playerId: number, index: number): Promise<boolean> {
    const session: PlayerSession = this.requireSession(playerId);
    if (this.isPlayableState(session.avPlayer.state)) {
      await session.avPlayer.deselectTrack(index);
      return true;
    }
    return false;
  }

  private async disposeSession(playerId: number): Promise<boolean> {
    const session: PlayerSession | undefined = this.sessions.get(playerId);
    if (session === undefined) {
      return false;
    }
    this.sessions.delete(playerId);
    session.disposed = true;
    session.streamHandler.clear();
    session.eventChannel.setStreamHandler(null);

    try {
      session.avPlayer.off('stateChange');
      session.avPlayer.off('timeUpdate');
      session.avPlayer.off('durationUpdate');
      session.avPlayer.off('bufferingUpdate');
      session.avPlayer.off('videoSizeChange');
      session.avPlayer.off('error');
    } catch (_err) {
      // Ignore listener detach errors during teardown.
    }

    try {
      await session.avPlayer.release();
    } catch (_err) {
      // Ignore release errors on already-released native instances.
    }

    try {
      if (this.textureRegistry !== null) {
        this.textureRegistry.unregisterTexture(session.textureId);
      } else {
        session.surfaceEntry.release();
      }
    } catch (_err) {
      // Ignore texture cleanup errors during engine detach.
    }
    return true;
  }
}

export default OhosAvPlayerPlugin;
