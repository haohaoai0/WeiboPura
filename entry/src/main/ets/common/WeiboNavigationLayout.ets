/** Window breakpoint and destination state shared by the root Weibo navigation. */
export const WEIBO_BREAKPOINT_KEY: string = 'weibo.breakpoint';
export const WEIBO_CONTENT_DESTINATION_OPEN_KEY: string = 'weibo.content_destination_open';

/** Matches HarmonyX: only an extra-wide window can show a source and destination together. */
export class WeiboResponsiveLayout {
  public static readonly BREAKPOINT_SM: string = 'sm';
  public static readonly BREAKPOINT_MD: string = 'md';
  public static readonly BREAKPOINT_LG: string = 'lg';
  public static readonly BREAKPOINT_XL: string = 'xl';

  public static breakpointForWidth(widthVp: number): string {
    if (widthVp < 600) {
      return WeiboResponsiveLayout.BREAKPOINT_SM;
    }
    if (widthVp < 840) {
      return WeiboResponsiveLayout.BREAKPOINT_MD;
    }
    if (widthVp < 1200) {
      return WeiboResponsiveLayout.BREAKPOINT_LG;
    }
    return WeiboResponsiveLayout.BREAKPOINT_XL;
  }

  public static isWide(breakpoint: string): boolean {
    return breakpoint === WeiboResponsiveLayout.BREAKPOINT_XL;
  }
}

/** Keeps the destination state in sync with normal and system back navigation. */
export function syncWeiboSplitNavigation(pathStack: NavPathStack): void {
  const pathNames: string[] = pathStack.getAllPathName();
  AppStorage.setOrCreate<boolean>(WEIBO_CONTENT_DESTINATION_OPEN_KEY, pathNames.length > 0);
}
