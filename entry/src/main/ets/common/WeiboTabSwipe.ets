import { hilog } from '@kit.PerformanceAnalysisKit';

// Dragging inside a large click target must never turn into a tap.
export const WEIBO_TAP_MAX_MOVEMENT: number = 12;

/** Direction is decided at the start, not repeatedly revoked during a thumb arc. */
export class WeiboTabSwipe {
  private active: boolean = false;
  private rejected: boolean = false;
  private horizontal: boolean = false;
  private startX: number = 0;
  private startY: number = 0;
  private lastX: number = 0;

  begin(x: number, y: number, _time: number): void {
    this.active = true;
    this.rejected = false;
    this.horizontal = false;
    this.startX = x;
    this.startY = y;
    this.lastX = x;
  }

  cancel(): void {
    this.active = false;
    this.rejected = true;
  }

  move(x: number, y: number): void {
    if (!this.active || this.rejected) { return; }
    this.lastX = x;
    if (this.horizontal) { return; }
    const dx: number = Math.abs(x - this.startX);
    const dy: number = Math.abs(y - this.startY);
    if (Math.max(dx, dy) < 8) { return; }
    if (dx >= 12 && dx >= dy * 1.5) {
      this.horizontal = true;
    } else if (dy >= 8 && dy >= dx) {
      // A scroll cannot turn into a tab switch on release.
      this.rejected = true;
    }
  }

  canClaim(): boolean {
    return this.active && !this.rejected && this.horizontal;
  }

  displacement(): number {
    return this.canClaim() ? this.lastX - this.startX : 0;
  }

  end(x: number, y: number, _time: number, velocityX: number = 0): number {
    this.move(x, y);
    const dx: number = this.lastX - this.startX;
    // Slow drags use travel; deliberate short flicks also use release velocity.
    // Neither path bypasses the native arena, initial axis lock or minimum travel.
    const flick: boolean = Math.abs(dx) >= 24 && Math.abs(velocityX) >= 500 && dx * velocityX > 0;
    const accepted: boolean = this.canClaim() && (Math.abs(dx) >= 48 || flick);
    this.cancel();
    return accepted ? (dx < 0 ? 1 : -1) : 0;
  }
}

/** Only a winning native PanGesture may commit; onTouch is trajectory evidence only. */
export class WeiboTabTouchTracker {
  private swipe: WeiboTabSwipe = new WeiboTabSwipe();
  private fingerId: number = -1;
  private owned: boolean = false;
  private scope: string;

  constructor(scope: string) { this.scope = scope; }

  cancel(): void {
    this.swipe.cancel();
    this.fingerId = -1;
    this.owned = false;
  }

  track(event: TouchEvent): void {
    if (event.type === TouchType.Cancel || event.touches.length > 1) {
      this.cancel();
      return;
    }
    if (event.changedTouches.length === 0) { return; }
    const point: TouchObject = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.owned = false;
      this.fingerId = point.id;
      this.swipe.begin(point.windowX, point.windowY, Date.now());
    } else if (point.id === this.fingerId) {
      // Up must not reset ownership before the native arena completes.
      this.swipe.move(point.windowX, point.windowY);
    }
  }

  judge(info: GestureInfo, event: BaseGestureEvent, enabled: boolean): GestureJudgeResult {
    if (info.tag !== 'weibo-tab-swipe') { return GestureJudgeResult.CONTINUE; }
    if (!enabled || event.fingerList.length !== 1 || !event.fingerList[0] ||
      event.fingerList[0].id !== this.fingerId) {
      return GestureJudgeResult.REJECT;
    }
    this.swipe.move(event.fingerList[0].globalX, event.fingerList[0].globalY);
    const allowed: boolean = this.swipe.canClaim();
    hilog.info(0x0001, 'FluoTabSwipe', '%{public}s judge=%{public}s', this.scope, `${allowed}`);
    return allowed ? GestureJudgeResult.CONTINUE : GestureJudgeResult.REJECT;
  }

  claim(): void { this.owned = this.swipe.canClaim(); }

  update(event: GestureEvent, canPrevious: boolean, canNext: boolean): number {
    if (!this.owned || event.fingerList.length !== 1 || !event.fingerList[0]) { return 0; }
    this.swipe.move(event.fingerList[0].globalX, event.fingerList[0].globalY);
    const dx: number = this.swipe.displacement();
    const atBoundary: boolean = dx > 0 ? !canPrevious : !canNext;
    // 1:1 near the origin, then elastic resistance; never changes layout geometry.
    const limit: number = atBoundary ? 24 : 120;
    return dx / (1 + Math.abs(dx) / limit);
  }

  finish(event: GestureEvent): number {
    let direction: number = 0;
    const dx: number = this.swipe.displacement();
    if (this.owned && event.fingerList.length === 1 && event.fingerList[0]) {
      direction = this.swipe.end(event.fingerList[0].globalX, event.fingerList[0].globalY,
        Date.now(), event.velocityX);
    }
    hilog.info(0x0001, 'FluoTabSwipe', '%{public}s owned=%{public}s dx=%{public}s vx=%{public}s direction=%{public}d',
      this.scope, `${this.owned}`, `${dx}`, `${event.velocityX}`, direction);
    this.cancel();
    return direction;
  }
}
