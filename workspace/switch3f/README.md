# Switch3F(三旺通信 3onedata,192.168.10.21)UI 參考檔

- `defLang.js`:交換機 web UI 語言檔(抓自 `http://192.168.10.21/lang/defLang.js`,
  2026-07-08)。選單鍵名前綴可反查頁面位置:`doc2Sec*`=安全、`fld2*`=選單群組。
- 常用定位:
  - SNMP 服務總開關:安全 → 管理访问权限(fld2SecMgmtAccess)→ 管理服务
    (doc2SecMgmtService;Telnet/SSH/HTTP/HTTPS/SNMP 清單)。
  - SNMP 設定家族:管理 → SNMP(查看/组/Community/用户/Engine ID/Trap事件/通知)。
- 坑:community 欄位建立時截斷為 20 字(表格顯示值=實值);SNMP 錯 community=靜默丟包
  (timeout),服務未開=ICMP refused——兩種症狀可據此分辨。詳見 ForAI/缺改記錄 2026-07-08。
