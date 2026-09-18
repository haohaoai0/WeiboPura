/**
 * Ephemeral anonymous session obtained from the visible Web runtime.
 * It is deliberately never written to CacheManager: closing the process or
 * destroying the incognito Web component discards it.
 */
export class WeiboVisitorSession {
  private static instance: WeiboVisitorSession | null = null;
  private cookie: string = '';

  static getInstance(): WeiboVisitorSession {
    if (WeiboVisitorSession.instance === null) {
      WeiboVisitorSession.instance = new WeiboVisitorSession();
    }
    return WeiboVisitorSession.instance;
  }

  update(cookie: string): void {
    const cleanCookie: string = cookie.trim();
    if (cleanCookie.includes('SUB=') && cleanCookie.includes('XSRF-TOKEN=')) {
      this.cookie = cleanCookie;
    }
  }

  getCookie(): string {
    return this.cookie;
  }

  isReady(): boolean {
    return this.cookie.length > 0;
  }

  clear(): void {
    this.cookie = '';
  }
}
