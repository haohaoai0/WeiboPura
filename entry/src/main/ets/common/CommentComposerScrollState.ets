/** Scroll deltas are vp: positive means reading further down, negative back up. */
export class CommentComposerScrollState {
  private hidden: boolean = false;
  private direction: number = 0;
  private distance: number = 0;

  reset(): void {
    this.hidden = false;
    this.direction = 0;
    this.distance = 0;
  }

  update(delta: number, commentsVisible: boolean, editing: boolean): boolean {
    if (!commentsVisible || editing) {
      this.reset();
      return false;
    }
    if (!Number.isFinite(delta) || delta === 0) { return this.hidden; }
    const direction: number = delta > 0 ? 1 : -1;
    if (direction !== this.direction) {
      this.direction = direction;
      this.distance = 0;
    }
    this.distance += Math.abs(delta);
    const threshold: number = this.hidden ? 12 : 24;
    if (this.distance >= threshold) {
      this.hidden = direction > 0;
      this.distance = 0;
    }
    return this.hidden;
  }
}
