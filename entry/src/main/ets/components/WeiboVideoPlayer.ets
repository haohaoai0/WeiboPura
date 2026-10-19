import { Theme, Radius, isDarkMode } from '../common/Theme';
import { deviceInfo } from '@kit.BasicServicesKit';

function formatVideoTime(seconds: number): string {
  if (isNaN(seconds) || seconds < 0) {
    return '00:00';
  }
  const total: number = Math.floor(seconds);
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  const mStr: string = m < 10 ? `0${m}` : `${m}`;
  const sStr: string = s < 10 ? `0${s}` : `${s}`;
  return `${mStr}:${sStr}`;
}

@Component
export struct WeiboVideoPlayer {
  @Prop src: string = '';
  @Prop cover: string = '';
  @Prop videoRatio: number = 16 / 9;
  @State viewportWidth: number = 360;
  @State rate: number = 1;
  @State failed: boolean = false;
  @State playing: boolean = false;
  @State showControls: boolean = true;
  @State fullscreen: boolean = false;
  private seeking: boolean = false;
  @State currentSeconds: number = 0;
  @State duration: number = 0;
  @State gestureHint: string = '';
  private controller: VideoController = new VideoController();
  private hideTimer: number = -1;
  private isDark: boolean = isDarkMode();

  aboutToDisappear(): void {
    this.clearHideTimer();
    try {
      this.controller.pause();
    } catch (_error) {}
  }

  private clearHideTimer(): void {
    if (this.hideTimer !== -1) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private scheduleControlsHide(): void {
    this.clearHideTimer();
    if (this.fullscreen || this.seeking) { return; }
    if (!this.playing) {
      this.showControls = true;
      return;
    }
    this.hideTimer = setTimeout((): void => {
      this.getUIContext().animateTo({ duration: 250 }, (): void => {
        this.showControls = false;
      });
      this.hideTimer = -1;
    }, 3500);
  }

  private toggleControls(): void {
    this.getUIContext().animateTo({ duration: 200 }, (): void => {
      this.showControls = !this.showControls;
    });
    if (this.showControls && this.playing) {
      this.scheduleControlsHide();
    } else {
      this.clearHideTimer();
    }
  }

  private togglePlayback(): void {
    if (this.playing) {
      this.controller.pause();
      this.playing = false;
      this.showControls = true;
      this.clearHideTimer();
    } else {
      this.controller.start();
      this.playing = true;
      this.scheduleControlsHide();
    }
  }

  private handleFullscreenChange(fullscreen: boolean): void {
    this.fullscreen = fullscreen;
    this.seeking = false;
    this.showControls = true;
    this.scheduleControlsHide();
  }

  private seekTo(value: number, mode: SliderChangeMode): void {
    this.clearHideTimer();
    this.seeking = true;
    this.currentSeconds = value;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.controller.setCurrentTime(value, SeekMode.Accurate);
      this.seeking = false;
      this.scheduleControlsHide();
    }
  }

  private cycleRate(): void {
    const values: number[] = deviceInfo.sdkApiVersion >= 22 ? [0.75, 1, 1.25, 1.5, 2] : [0.75, 1, 1.25, 1.75, 2];
    const nextIndex: number = (values.indexOf(this.rate) + 1) % values.length;
    this.rate = values[nextIndex];
    if (this.playing) {
      this.scheduleControlsHide();
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Video({
        src: this.src,
        previewUri: this.cover,
        controller: this.controller,
        currentProgressRate: this.rate
      })
        .width('100%')
        .height('100%')
        // Native fullscreen moves only Video, not the sibling custom overlay.
        // Enable its own controller there so seeking/play/pause/exit stay available.
        .controls(this.fullscreen)
        .onFullscreenChange((event): void => {
          this.handleFullscreenChange(event.fullscreen);
        })
        .autoPlay(false)
        .objectFit(ImageFit.Contain)
        .backgroundColor(Color.Black)
        .onPrepared((event): void => {
          this.duration = event.duration;
          this.failed = false;
        })
        .onUpdate((event): void => {
          if (!this.seeking) { this.currentSeconds = event.time; }
        })
        .onStart((): void => {
          this.playing = true;
          this.scheduleControlsHide();
        })
        .onPause((): void => {
          this.playing = false;
          this.showControls = true;
          this.clearHideTimer();
        })
        .onFinish((): void => {
          this.playing = false;
          this.showControls = true;
          this.clearHideTimer();
        })
        .onError((): void => {
          this.failed = true;
          this.playing = false;
        })
        .onVisibleAreaChange([0.0], (isVisible: boolean, _currentRatio: number): void => {
          if (!isVisible && this.playing) {
            try {
              this.controller.pause();
            } catch (_err) {}
            this.playing = false;
            this.showControls = true;
            this.clearHideTimer();
          }
        })

      // Gesture tap area
      Row()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .onClick((): void => {
          this.toggleControls();
        })
        .parallelGesture(TapGesture({ count: 2 }).onAction((): void => {
          this.togglePlayback();
        }))

      // Center play/replay button when paused or finished
      if (!this.playing && !this.failed) {
        Stack({ alignContent: Alignment.Center }) {
          Polygon({ width: 22, height: 26 })
            .points([[0, 0], [22, 13], [0, 26]])
            .fill(Color.White)
            .margin({ left: 4 })
        }
        .width(62)
        .height(62)
        .backgroundColor('rgba(0, 0, 0, 0.60)')
        .border({ width: 1.5, color: 'rgba(255, 255, 255, 0.40)' })
        .borderRadius(31)
        .shadow({ radius: 18, color: 'rgba(0, 0, 0, 0.45)', offsetY: 4 })
        .hitTestBehavior(HitTestMode.Default)
        .accessibilityText('播放视频')
        .onClick((): void => {
          this.togglePlayback();
        })
      }

      // Gesture scrubbing overlay
      if (this.gestureHint.length > 0) {
        Text(this.gestureHint)
          .fontColor(Color.White)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('rgba(0, 0, 0, 0.75)')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .borderRadius(Radius.md)
      }

      // Error banner
      if (this.failed) {
        Text('视频加载失败，请重新进入或检查网络')
          .fontColor(Color.White)
          .fontSize(13)
          .padding(14)
          .backgroundColor('rgba(0, 0, 0, 0.75)')
          .borderRadius(Radius.md)
      }

      // Sleek official-grade bottom control bar overlay
      if (this.showControls && !this.failed && !this.fullscreen) {
        Row({ space: 8 }) {
          // Play / Pause toggle
          Button() {
            if (this.playing) {
              Row({ space: 3 }) {
                Rect({ width: 3.5, height: 13 }).fill(Color.White).radius(1)
                Rect({ width: 3.5, height: 13 }).fill(Color.White).radius(1)
              }
            } else {
              Polygon({ width: 12, height: 14 })
                .points([[0, 0], [12, 7], [0, 14]])
                .fill(Color.White)
                .margin({ left: 2 })
            }
          }
          .width(32)
          .height(32)
          .backgroundColor('rgba(255, 255, 255, 0.15)')
          .borderRadius(16)
          .accessibilityText(this.playing ? '暂停视频' : '播放视频')
          .onClick((): void => {
            this.togglePlayback();
          })

          // Time text
          Text(`${formatVideoTime(this.currentSeconds)} / ${formatVideoTime(this.duration)}`)
            .fontSize(11)
            .fontColor('rgba(255, 255, 255, 0.90)')
            .fontWeight(FontWeight.Medium)

          // Progress slider
          Slider({
            value: this.currentSeconds,
            min: 0,
            max: Math.max(1, this.duration),
            step: 1
          })
            .layoutWeight(1)
            .trackColor('rgba(255, 255, 255, 0.28)')
            .selectedColor(Theme.brand())
            .blockColor(Color.White)
            .trackThickness(3)
            .onChange((value: number, mode: SliderChangeMode): void => {
              this.seekTo(value, mode);
            })

          // Speed selector pill
          Button(`${this.rate}×`)
            .height(26)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('rgba(255, 255, 255, 0.18)')
            .borderRadius(13)
            .padding({ left: 8, right: 8 })
            .accessibilityText(`视频倍速 ${this.rate} 倍`)
            .onClick((): void => {
              this.cycleRate();
            })

          // Fullscreen button
          Button() {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.arrow_up_left_and_arrow_down_right'))
                .fontSize(15)
                .fontColor([Color.White])
            }
          }
          .width(30)
          .height(30)
          .backgroundColor('rgba(255, 255, 255, 0.15)')
          .borderRadius(15)
          .accessibilityText('视频全屏')
          .onClick((): void => {
            this.fullscreen = true;
            this.clearHideTimer();
            this.controller.requestFullscreen(true);
          })
        }
        .width('100%')
        .height(48)
        .padding({ left: 12, right: 12, bottom: 4 })
        .linearGradient({
          angle: 180,
          colors: [
            ['rgba(0, 0, 0, 0)', 0],
            ['rgba(0, 0, 0, 0.75)', 1]
          ]
        })
        .position({ x: 0, y: '100%' })
        .markAnchor({ x: 0, y: '100%' })
        .hitTestBehavior(HitTestMode.Default)
      }
    }
    .width('100%')
    .height(Math.min(520, this.viewportWidth / Math.max(0.5, this.videoRatio)))
    .backgroundColor(Color.Black)
    .borderRadius(16)
    .border({ width: 0.5, color: Theme.cardBorder(this.isDark) })
    .clip(true)
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Number(area.width);
    })
  }
}
