import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { pushService } from '@kit.PushKit';
import { notificationManager } from '@kit.NotificationKit';
import { ChatClient } from '../services/ChatClient';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'DafeiyuIM';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'Ability onCreate');
    this.handleWant(want);
    // 数据消息（App 在前台时由这里接收）；通知消息由系统直接弹，不走这里
    try {
      pushService.receiveMessage('DEFAULT', this, (payload: object) => {
        const raw: string = JSON.stringify(payload ?? {});
        hilog.info(0x0000, TAG, '[PUSH] message: %{public}s', raw);
        this.showLocalNotification(raw);
      });
      // 首次启动申请通知权限（重装后会被重置，所以每次启动都问一次）
      notificationManager.isNotificationEnabled().then((on: boolean) => {
        hilog.info(0x0000, TAG, '[PUSH] notification enabled = %{public}s', String(on));
        if (!on) {
          notificationManager.requestEnableNotification().then(() => {
            hilog.info(0x0000, TAG, '[PUSH] notification granted');
          }).catch((e: object) => {
            hilog.warn(0x0000, TAG, '[PUSH] requestEnableNotification rejected');
          });
        }
      }).catch((e: object) => {
        hilog.warn(0x0000, TAG, '[PUSH] isNotificationEnabled failed');
      });
      hilog.info(0x0000, TAG, '[PUSH] receiveMessage registered');
    } catch (e) {
      hilog.error(0x0000, TAG, '[PUSH] receiveMessage threw');
    }
  }

  // 收到推送后自己弹一条本地通知：标题/正文从 data 里取，点开走 dafeiyu://chat?threadId=
  private showLocalNotification(raw: string): void {
    let title = '大肥鱼';
    let body = '有新消息';
    let threadId = '';
    try {
      const root: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const dataNode: Record<string, Object> = (root.data ?? root) as Record<string, Object>;
      if (typeof dataNode.title === 'string') { title = dataNode.title as string; }
      if (typeof dataNode.body === 'string') { body = dataNode.body as string; }
      if (typeof dataNode.threadId === 'string') { threadId = dataNode.threadId as string; }
    } catch (e) {
      hilog.warn(0x0000, TAG, '[PUSH] parse payload failed');
    }
    const request: notificationManager.NotificationRequest = {
      id: threadId === '' ? 1001 : Math.abs(this.hashCode(threadId)) % 100000 + 1000,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: body,
          additionalText: threadId === '' ? undefined : '点开继续聊',
        },
      },
      wantAgent: undefined,
    };
    try {
      notificationManager.publish(request, (err: object) => {
        if (err) {
          hilog.error(0x0000, TAG, '[PUSH] publish failed: %{public}s', JSON.stringify(err));
        } else {
          hilog.info(0x0000, TAG, '[PUSH] publish ok');
        }
      });
    } catch (e) {
      hilog.error(0x0000, TAG, '[PUSH] publish threw');
    }
  }

  private hashCode(s: string): number {
    let h: number = 0;
    for (let i = 0; i < s.length; i++) {
      h = (h * 31 + s.charCodeAt(i)) | 0;
    }
    return h;
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleWant(want);
  }

  // 从推送通知点进来时带 threadId，交给页面切会话
  private handleWant(want: Want): void {
    try {
      const p: Record<string, Object> = (want.parameters ?? {}) as Record<string, Object>;
      let tid: string = '';
      const raw: string = typeof p['data'] === 'string' ? p['data'] as string : '';
      if (raw.length > 0) {
        try {
          const obj: Record<string, string> = JSON.parse(raw) as Record<string, string>;
          tid = obj.threadId ?? '';
        } catch (e) {
          tid = '';
        }
      }
      if (tid.length === 0 && typeof p['threadId'] === 'string') {
        tid = p['threadId'] as string;
      }
      if (tid.length > 0) {
        hilog.info(0x0000, TAG, '[PUSH] open thread: %{public}s', tid);
        AppStorage.setOrCreate<string>('openThread', tid);
      }
    } catch (e) {
      hilog.error(0x0000, TAG, '[PUSH] handleWant failed');
    }
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 字体注册放在页面 aboutToAppear（Ability 阶段注册不生效），这里不再重复
    // 全屏沉浸：内容一直画到屏幕底部，安全区留白由页面自己算
    try {
      windowStage.getMainWindow().then((win: window.Window) => {
        win.setWindowLayoutFullScreen(true).catch((e: Error) => {
          hilog.error(0x0000, TAG, 'setWindowLayoutFullScreen failed: %{public}s', e.message);
        });
      }).catch((e: Error) => {
        hilog.error(0x0000, TAG, 'getMainWindow failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.error(0x0000, TAG, 'fullscreen setup threw');
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent ok');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'WindowStage destroyed');
  }

  onForeground(): void {
    hilog.info(0x0000, TAG, 'onForeground');
    ChatClient.notifyForeground(true);
  }

  onBackground(): void {
    hilog.info(0x0000, TAG, 'onBackground');
    ChatClient.notifyForeground(false);
  }
}
