# mc-autosleep —— MC 伺服器自動休眠/喚醒(待辦51,2026-07-10 上線)

無人 10 分鐘自動關服;白名單玩家 join 進等待室(boss bar)自動喚醒並送入;
備份期間嚴格不開機(flock 互斥);喚醒/關服發 TG。詳見 V7 §7 與缺改記錄。

## 佈局(SoT=本目錄;live 檔案位置見各小節)

- `ct100/mc-gate.py` → CT100 `/root/mc-gate.py`(systemd `mc-gate.service`,:25580)
  token 在 CT100 `/root/mc-gate.env`(600,不入庫);MCSM 憑證複用 `/root/mcsm.env`
- `ct100/mc-gate.service` → CT100 `/etc/systemd/system/mc-gate.service`
- `ct100/mc-safe-backup.sh` → CT100 `/root/mc-safe-backup.sh`(WAS_RUNNING 版)
- `ct100/nftables.conf` → CT100 `/etc/nftables.conf`(加 10.70.70.10→tcp/25580)
- `ct102/mc-gate.sh` → CT102 `/opt/velocity/mc-gate.sh`(token env 同目錄,600 velocity)
- `ct102/limboautoserver-config.toml` → CT102 `/opt/velocity/plugins/limboautoserver/config.toml`
- `ct102/velocitywhitelist-config.yml` → CT102 `/opt/velocity/plugins/velocitywhitelist/config.yml`
- `ct260/hl-mc-watch` → CT260 `~/.local/bin/hl-mc-watch`(cron */2)

## 插件 jar(不入庫;/opt/velocity/plugins/)

| jar | 來源 | sha256 |
|---|---|---|
| limboapi-1.1.27-SNAPSHOT.jar | github.com/Elytrium/LimboAPI releases tag `dev-build` | 18ac6287d413234c4fc317267a6d5dbf978adae8bf3f098a1248966bf2c32ce9 |
| limboautoserver-velocity-1.0.0-beta.1.jar | github.com/Uxzylon/LimboAutoServer v1.0.0-beta.1 | 57b722526101cff90402c8ceace07c78c0ae331c2397de7d59299d7d274edf29 |
| VelocityWhitelist-1.1.0-SNAPSHOT.jar | hangar.papermc.io gmisi/VelocityWhitelist 1.1.0-SNAPSHOT | e2799d215b578bd09eae65fb0b3403e783d83075799b47a4ba6bbc739abf8d05 |

## 等待室建築(worldfile 補丁,2026-07-10)

- 上游 beta.1 只有虛空;本目錄 `limboautoserver-worldfile.patch` 給 LimboAutoServer 加
  `limbo.worldFile*` 設定(LimboAPI WorldFile API,SCHEMATIC/WORLDEDIT_SCHEM/STRUCTURE),
  fail-open:任何設定/檔案錯誤只退回虛空,不炸 proxy(對抗審查抓到 toml4j 硬轉型
  ClassCastException 逃逸鏈,已以整方法 try/catch 收束=worldfile.2)。
- 現行 jar:`limboautoserver-velocity-1.0.0-beta.1+worldfile.2.jar`
  (sha256 95fc18b90f3dccf0005a79fbe9c7abb08aab27b5c5b28c7b044c16cc5f71c8f2;
  重建:clone 上游 → `git apply limboautoserver-worldfile.patch` → JDK17+ `./gradlew build`)。
- 建築:Modern House by Raaamseeel(abfielder id=8717,76×46×118,Sponge schem v2)。
  ★ BlockEntities 已全剝(777 個,含 664 告示牌):LimboAPI SimpleBlockEntity 對新式
  BE 型別映射 NPE 會炸 createLimbo。換建築時同樣要先剝(nbtlib 置空 BlockEntities)。
- 佈局:貼圖原點 (0,64,0),出生點=天台 (38.5, 96.2, 59.5)(schem 屋頂主平面 y=31)。
- 上游 PR 建議:worldFile 功能+CCE fail-open 修法可回饋 Uxzylon/LimboAutoServer(待使用者
  用自己 GitHub 帳號發,Agent 不代發)。

## 白名單維護

改 CT102 `plugins/velocitywhitelist/config.yml` 的 `servers.VelocityProxy.whitelisted`
(鏡像 CT100 `/root/minecraft/whitelist.json`),遊戲內 `/vwl reload` 或重啟 velocity。
後端 whitelist.json 仍為第二道閘,兩邊都要加。

## 回滾

- 全部退場:CT102 刪三 jar+還原 `/root/_backups/velocity.toml.before-autosleep-*` 重啟 velocity;
  CT100 `systemctl disable --now mc-gate`+還原 `_backups/nftables.conf.before-mcgate-*`(nft -f)
  +還原 `_backups/mc-safe-backup.sh.before-autosleep-*`;CT260 crontab 刪 hl-mc-watch 行。
- 備份副本另存 CT260 `~/_backups/mc-autosleep-20260710/`。

## 已知取捨

- 等待室訊息為靜態文字(無法動態顯示「備份中」);備份窗內喚醒由 hook 等鎖(≤300s)後才開機。
- LimboAutoServer 為 beta.1;異常時按上面回滾,hook/備份腳本改動可獨立保留。
- 檢查 Java 進程要用 `pgrep -f "[j]ava.*fabric"`(避免自匹配)。
