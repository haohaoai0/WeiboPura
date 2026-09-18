/*
 * TiebaPura - HarmonyOS 原生 ArkTS 实现的第三方百度贴吧客户端
 * Copyright (C) 2026 a307608689-afk
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/**
 * 全局常量与工具函数
 */

// 贴吧基础域名
export const TIEBA_HOST: string = 'https://tieba.baidu.com';

// API 端点接口
export interface ApiEndpoints {
  HOME: string;
  FORUM_THREADS: string;
  THREAD: string;
  SEARCH_FORUM: string;
  FOLLOW_LIST: string;
  LIKE_FORUM: string;
  USER_HOME: string;
  MESSAGE: string;
  PERSONALIZED: string;
  FORUM_PAGE: string;
  USER_LIKE_FORUM: string;
  /** 官方一键签到（msign）：一次请求让服务端批量签到多个吧 */
  FORUM_MSIGN: string;
  BLACKLIST: string;
  BLACKLIST_ADD: string;
  BLACKLIST_DEL: string;
  BLACKLIST_SET_USER: string;
  BLACKLIST_PAGE: string;
  FOLLOW_ADD: string;
  FOLLOW_DEL: string;
  FOLLOW_USER_LIST: string;
}

// 各端点
export const API: ApiEndpoints = {
  HOME: `${TIEBA_HOST}/f/index/forumpark?cn=0&ci=0&pcn=热门推荐&pci=0&ct=1&rn=30&pn=`,
  FORUM_THREADS: `${TIEBA_HOST}/f?ie=utf-8&kw=`,
  THREAD: `${TIEBA_HOST}/p/`,
  SEARCH_FORUM: `${TIEBA_HOST}/f/search/res?ie=utf-8&qw=`,
  FOLLOW_LIST: `${TIEBA_HOST}/f/like/mylike?&pn=`,
  LIKE_FORUM: `${TIEBA_HOST}/mo/q/newmoindex`,
  USER_HOME: `${TIEBA_HOST}/home/main`,
  MESSAGE: `${TIEBA_HOST}/msg/index`,
  PERSONALIZED: 'https://c.tieba.baidu.com/c/f/excellent/personalized',
  FORUM_PAGE: 'https://c.tieba.baidu.com/c/f/frs/page',
  USER_LIKE_FORUM: 'https://c.tieba.baidu.com/c/f/forum/like',
  FORUM_MSIGN: 'https://tiebac.baidu.com/c/c/forum/msign',
  // 已抓包确认（批A，2026-08-31 aiotieba + tbclient.protobuf 对照）：
  // 黑名单查询接口位于 tiebac.baidu.com，走 protobuf 通道（Cmd 303028，老接口，仅查询仍可用）。
  // 写接口说明（2026-09-01 实测）：
  //   老 userMuteAdd/userMuteDel（JSON form）已被服务端标记为「高级会员权限」（1990043），普通账号不可用；
  //   官方 App 已切换到新版 SetUserBlack（protobuf 通道 Cmd 309697），支持三个精细化开关，
  //   实现参考 aiotieba set_blacklist + tbclient.protobuf proto/SetUserBlack/。
  //   字段编号：
  //     SetUserBlackReqIdl: data(1){ common(1), black_uid(2), perm_list(3){ follow(1), interact(2), chat(3) } }
  //     SetUserBlackResIdl: error(1){ errorno(1), errmsg(2) }, data(2)（空）
  //   perm_list 取值：1=开启屏蔽，2=不屏蔽（服务端约定）。
  BLACKLIST: 'https://tiebac.baidu.com/c/u/user/userMuteQuery?cmd=303028',
  BLACKLIST_ADD: 'https://tiebac.baidu.com/c/c/user/userMuteAdd',
  BLACKLIST_DEL: 'https://tiebac.baidu.com/c/c/user/userMuteDel',
  BLACKLIST_SET_USER: 'https://tiebac.baidu.com/c/c/user/setUserBlack?cmd=309697',
  // 2026-09-01 定案：新版黑名单查询走 JSON form 接口 userBlackPage（aiotieba get_blacklist 对照），
  // 返回 data.user_perm_list[]，每项带 perm_list{ follow, interact, chat }——官方 App 三开关回显的数据来源。
  // 请求参数 BDUSS + _client_version + sign；无分页参数，一次返回全部。
  BLACKLIST_PAGE: 'https://tiebac.baidu.com/c/u/user/userBlackPage',
  // 已抓包确认（批A，2026-08-31 模拟器 + hilog 探测）：关注相关接口均位于 tiebac.baidu.com，
  // 需携带 BDUSS + _client_version + sign（MD5 小写，salt=tiebaclient!!!），见 TiebaService.signTiebaForm
  FOLLOW_ADD: 'https://tiebac.baidu.com/c/c/user/follow',
  FOLLOW_DEL: 'https://tiebac.baidu.com/c/c/user/unfollow',
  FOLLOW_USER_LIST: 'https://tiebac.baidu.com/c/u/follow/followList',
};

// 登录态 Cookie 键名（贴吧核心为 BDUSS）
export const COOKIE_BDUSS: string = 'BDUSS';

// 缓存键接口
export interface CacheKeys {
  LOGIN_COOKIE: string;
  LOGIN_USER: string;
  THREAD_LIST: string;
  FORUM_LIST: string;
  FOLLOW_LIST: string;
  THREAD_DETAIL: string;
  PERSONAL_HISTORY: string;
  PERSONAL_COLLECTED: string;
  PERSONAL_LIKED: string;
  PERSONAL_COLLECTED_META: string;
  FONT_SIZE_LEVEL: string;
  FAVORITE_PIN_FOLDER: string;
  FAVORITE_PIN_THREAD: string;
  FAVORITE_CUSTOM_FOLDER: string;
  FAVORITE_CUSTOM_MAPPING: string;
  SEARCH_HISTORY: string;
  FAVORITE_SORT_MODE: string;
  FAVORITE_COLLECT_TS: string;
  FAVORITE_CUSTOM_THREAD_ORDER: string;
  AUTHOR_NICK: string;
  BLACKLIST_SORT: string;
  /** 黑名单 perm 本地记忆（black_perm_{uid}，查询接口失败时的回显兜底） */
  BLACKLIST_PERM: string;
  USER_PROFILE_CACHE: string;
  USER_POSTS_SORT: string;
  FOLLOW_USER_LIST_CACHE: string;
  FOLLOW_LIST_SORT: string;
  FOLLOW_LIST_MODE: string;
  /** 进吧「我关注的吧」排序偏好（关注吧列表专用，与关注用户列表 FOLLOW_LIST_SORT 独立） */
  FOLLOW_FORUM_SORT: string;
  /** 进吧「我关注的吧」置顶列表（forumName 数组，置顶恒顶） */
  PIN_FOLLOW_FORUM: string;
  /** 首页推荐仅显示关注吧的帖子开关 */
  HOME_ONLY_FOLLOW: string;
  /**
   * 阔直屏「关闭自动旋转」开关（'1' = 已关闭自动旋转、固定竖屏；缺省/其他 = 允许旋转）。
   * 仅阔直屏直板形态显示与生效，见 Theme.isWideBarFlatDevice()
   */
  AUTO_ROTATE: string;
  /** 软件手动深色模式（仅当 FOLLOW_SYSTEM_DARK=false 时生效；冷启动不再跟随系统时的回退值） */
  DARK_MODE: string;
  /** 是否跟随系统深色模式开关（默认 true：保持原 v1.x 「跟随系统」行为，首次启动不读 DARK_MODE） */
  FOLLOW_SYSTEM_DARK: string;
  /** 关注动态聚合结果（按账号隔离，stale-while-revalidate：命中即秒开再后台刷新） */
  FOLLOW_FEED: string;
  /** 关注用户列表快照（按账号隔离：冷启动命中免一次列表 RTT，后台刷新回写） */
  FOLLOW_USERS: string;
  /** 一键签到·慢速模式开关（开启后逐吧签到间隔更长） */
  AUTO_SIGN_SLOW_MODE: string;
  /** 一键签到·优先使用官方一键签到开关（先用官方批量签到减少需签到吧数量） */
  AUTO_SIGN_USE_OFFICIAL: string;
  /** 单吧签到本地状态（按账号 + 吧名隔离：{ date, days }，用于返回重进后回显已签到） */
  FORUM_SIGN_STATE: string;
  /** 已同意的隐私政策版本号：与 PRIVACY_POLICY_VERSION 比对，版本不一致需重新征得同意 */
  PRIVACY_AGREED: string;
  /**
   * 「列数调整」档位（'0' = 默认自动适配 / '1' = 竖二横三 / '2' = 竖三横四）。
   * 仅在大屏形态（平板 / 2in1 / 阔直屏展开 / 大折叠展开 / Pura X Max 展开）生效；
   * 缺省 null → 默认档，老用户升级逐像素零回归。
   */
  COLUMN_MODE: string;
}

// 缓存键
export const CACHE_KEY: CacheKeys = {
  LOGIN_COOKIE: 'tieba_login_cookie',
  LOGIN_USER: 'tieba_login_user',
  THREAD_LIST: 'tieba_thread_list',
  FORUM_LIST: 'tieba_forum_list_v1',
  FOLLOW_LIST: 'tieba_follow_list',
  THREAD_DETAIL: 'tieba_thread_detail',
  PERSONAL_HISTORY: 'tieba_personal_history',
  PERSONAL_COLLECTED: 'tieba_personal_collected',
  PERSONAL_LIKED: 'tieba_personal_liked',
  PERSONAL_COLLECTED_META: 'tieba_personal_collected_meta',
  FONT_SIZE_LEVEL: 'tieba_font_size_level',
  FAVORITE_PIN_FOLDER: 'favorite_pin_folder',
  FAVORITE_PIN_THREAD: 'favorite_pin_thread',
  FAVORITE_CUSTOM_FOLDER: 'favorite_custom_folder',
  FAVORITE_CUSTOM_MAPPING: 'favorite_custom_mapping',
  SEARCH_HISTORY: 'tieba_search_history',
  FAVORITE_SORT_MODE: 'favorite_sort_mode',
  FAVORITE_COLLECT_TS: 'favorite_collect_ts',
  FAVORITE_CUSTOM_THREAD_ORDER: 'favorite_custom_thread_order',
  AUTHOR_NICK: 'author_nick_cache_v1',
  BLACKLIST_SORT: 'blacklist_sort',
  BLACKLIST_PERM: 'blacklist_perm',
  USER_PROFILE_CACHE: 'user_profile_cache',
  USER_POSTS_SORT: 'user_posts_sort',
  FOLLOW_USER_LIST_CACHE: 'follow_user_list_cache',
  FOLLOW_LIST_SORT: 'follow_list_sort',
  FOLLOW_LIST_MODE: 'follow_list_mode',
  FOLLOW_FORUM_SORT: 'follow_forum_sort',
  PIN_FOLLOW_FORUM: 'pin_follow_forum',
  HOME_ONLY_FOLLOW: 'tieba_home_only_follow',
  AUTO_ROTATE: 'tieba_auto_rotate',
  DARK_MODE: 'tieba_dark_mode',
  FOLLOW_SYSTEM_DARK: 'tieba_follow_system_dark',
  FOLLOW_FEED: 'tieba_follow_feed',
  FOLLOW_USERS: 'tieba_follow_users',
  AUTO_SIGN_SLOW_MODE: 'auto_sign_slow_mode',
  AUTO_SIGN_USE_OFFICIAL: 'auto_sign_use_official',
  FORUM_SIGN_STATE: 'tieba_forum_sign_state',
  PRIVACY_AGREED: 'tieba_privacy_agreed',
  COLUMN_MODE: 'tieba_column_mode',
};

// 缓存过期时间接口
export interface CacheTtls {
  THREAD_LIST: number;
  FORUM_LIST: number;
  FOLLOW_LIST: number;
  THREAD_DETAIL: number;
  AUTHOR_NICK: number;
  USER_PROFILE: number;
  FOLLOW_FEED: number;
  FOLLOW_USERS: number;
}

// 缓存过期时间（毫秒）
export const CACHE_TTL: CacheTtls = {
  THREAD_LIST: 5 * 60 * 1000,   // 5 分钟
  FORUM_LIST: 5 * 60 * 1000,    // 5 分钟：吧列表快照，命中即秒开再后台刷新
  FOLLOW_LIST: 30 * 60 * 1000,  // 30 分钟
  THREAD_DETAIL: 10 * 60 * 1000,
  AUTHOR_NICK: 7 * 24 * 3600 * 1000, // 7 天：昵称可能随时间变化，过期后重新校准
  USER_PROFILE: 5 * 60 * 1000,       // 5 分钟：用户主页资料，秒开辅助 + 关注态刷新
  FOLLOW_FEED: 5 * 60 * 1000,        // 5 分钟：关注动态聚合快照，命中即秒开再后台刷新
  FOLLOW_USERS: 10 * 60 * 1000,      // 10 分钟：关注列表变化不频繁，过期可 stale 复用
};

// 隐私政策（首启同意弹窗 + 应用市场「隐私政策网址」共用同一份在线政策）
/** 隐私政策版本号：政策内容实质变更时同步递增，已同意旧版本的用户会重新收到同意弹窗 */
export const PRIVACY_POLICY_VERSION: string = '1.0.0';
/** 隐私政策在线地址（GitHub 渲染页；与仓库 docs/PRIVACY.md 同源） */
export const PRIVACY_POLICY_URL: string =
  'https://github.com/a307608689-afk/TiebaPura/blob/main/docs/PRIVACY.md';

// 主题色（贴吧蓝）
export const BRAND_BLUE: string = '#E6162D';
export const BRAND_BLUE_LIGHT: string = '#F05A6E';

/**
 * HTML 实体解码
 */
export function decodeHtmlEntities(input: string): string {
  if (!input) {
    return '';
  }
  let result = input;
  result = result.replace(/&nbsp;/g, ' ');
  result = result.replace(/&lt;/g, '<');
  result = result.replace(/&gt;/g, '>');
  result = result.replace(/&quot;/g, '"');
  result = result.replace(/&#39;/g, "'");
  result = result.replace(/&amp;/g, '&');
  result = result.replace(/<br\s*\/?>/gi, '\n');
  return result;
}

/**
 * 去除 HTML 标签，保留文本
 */
export function stripHtml(input: string): string {
  if (!input) {
    return '';
  }
  let result = input.replace(/<script[\s\S]*?<\/script>/gi, '');
  result = result.replace(/<style[\s\S]*?<\/style>/gi, '');
  result = result.replace(/<[^>]+>/g, '');
  return decodeHtmlEntities(result).trim();
}

/**
 * 提取图片 URL（贴吧图片常用 http 协议，转为 https）
 */
export function extractImages(html: string): string[] {
  if (!html) {
    return [];
  }
  const result: string[] = [];
  const imgRegex = /<img[^>]+src=["']([^"']+)["']/gi;
  let match: RegExpExecArray | null = imgRegex.exec(html);
  while (match !== null) {
    let url = match[1];
    if (url.startsWith('//')) {
      url = 'https:' + url;
    } else if (url.startsWith('http://')) {
      url = url.replace('http://', 'https://');
    }
    if (url && !result.includes(url)) {
      result.push(url);
    }
    match = imgRegex.exec(html);
  }
  return result;
}

/**
 * 提取单个正则捕获组
 */
export function extractGroup(input: string, regex: RegExp): string {
  const m = regex.exec(input);
  return m ? (m[1] ?? '') : '';
}

/**
 * 时间戳友好格式化
 */
export function formatTime(input: string | number): string {
  if (!input) {
    return '';
  }
  let ts: number;
  if (typeof input === 'number') {
    ts = input;
  } else {
    ts = parseInt(input, 10);
    if (isNaN(ts)) {
      return input;
    }
  }
  // 自动检测：秒级(10位)→转毫秒；毫秒级(13位)直接用
  if (ts > 0 && ts < 100000000000) {
    // 10位左右，秒级时间戳，转毫秒
    ts = ts * 1000;
  }
  const now = Date.now();
  const diff = now - ts;
  if (diff < 0) {
    // 时间戳异常，返回空
    return '';
  }
  if (diff < 60 * 1000) {
    return '刚刚';
  }
  if (diff < 60 * 60 * 1000) {
    return `${Math.floor(diff / 60000)} 分钟前`;
  }
  if (diff < 24 * 60 * 60 * 1000) {
    return `${Math.floor(diff / 3600000)} 小时前`;
  }
  const d = new Date(ts);
  const y = d.getFullYear();
  const mo = (d.getMonth() + 1).toString().padStart(2, '0');
  const day = d.getDate().toString().padStart(2, '0');
  const h = d.getHours().toString().padStart(2, '0');
  const mi = d.getMinutes().toString().padStart(2, '0');
  if (y === new Date().getFullYear()) {
    return `${mo}-${day} ${h}:${mi}`;
  }
  return `${y}-${mo}-${day}`;
}

/**
 * Adapts Weibo's mixed `created_at` values to the same friendly format used by TiebaPura cards.
 * Weibo may return an epoch, an English RFC-like date, or short Chinese strings such as “今天 12:34”.
 */
export function formatWeiboTime(input: string): string {
  const value: string = input.trim();
  if (value.length === 0) {
    return '';
  }
  if (/^\d{10,13}$/.test(value)) {
    return formatTime(parseInt(value, 10));
  }
  if (value === '刚刚') {
    return '刚刚';
  }
  const minuteMatch: RegExpExecArray | null = /^(\d+)\s*分钟前$/.exec(value);
  if (minuteMatch !== null) {
    return `${minuteMatch[1]} 分钟前`;
  }
  const hourMatch: RegExpExecArray | null = /^(\d+)\s*小时前$/.exec(value);
  if (hourMatch !== null) {
    return `${hourMatch[1]} 小时前`;
  }
  const todayMatch: RegExpExecArray | null = /^今天\s*(\d{1,2}):(\d{2})$/.exec(value);
  if (todayMatch !== null) {
    const now: Date = new Date();
    const date: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
      parseInt(todayMatch[1], 10), parseInt(todayMatch[2], 10), 0);
    return formatTime(date.getTime());
  }
  const yesterdayMatch: RegExpExecArray | null = /^昨天\s*(\d{1,2}):(\d{2})$/.exec(value);
  if (yesterdayMatch !== null) {
    const now: Date = new Date();
    const date: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1,
      parseInt(yesterdayMatch[1], 10), parseInt(yesterdayMatch[2], 10), 0);
    return formatTime(date.getTime());
  }
  const monthDayMatch: RegExpExecArray | null = /^(\d{1,2})-(\d{1,2})$/.exec(value);
  if (monthDayMatch !== null) {
    const now: Date = new Date();
    let year: number = now.getFullYear();
    const month: number = parseInt(monthDayMatch[1], 10) - 1;
    const day: number = parseInt(monthDayMatch[2], 10);
    const date: Date = new Date(year, month, day, 0, 0, 0);
    if (date.getTime() > now.getTime()) {
      year--;
    }
    return formatTime(new Date(year, month, day, 0, 0, 0).getTime());
  }
  const parsed: number = Date.parse(value);
  if (!isNaN(parsed)) {
    return formatTime(parsed);
  }
  return value;
}
