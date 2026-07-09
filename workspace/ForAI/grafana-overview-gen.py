#!/usr/bin/env python3
# 產生 Grafana 中文總覽 dashboard: CT201 /opt/monitoring/grafana-dashboards/homelab-overview.json
# 設備中文名 + 固定排序來自 prometheus.yml 每個 target 的 device / order label。
# 改名稱/順序 -> 改 prometheus.yml 的 labels(device/order)後 reload prometheus;改面板 -> 改本檔重跑 + pct push。
# 排序靠 PromQL sort_by_label(需 prometheus --enable-feature=promql-experimental-functions)。
import json

DS = {"type": "prometheus", "uid": "prometheus"}
NODE = 'order=~"(0[1-9]|1[01])"'  # 11 台 node_exporter 設備 (order 01-11: CT100/102/201/202/203/260/270, VM300, 24Bay, DXP, RouterPVE), 同時排除改 label 前的 stale series
ALL = 'order!=""'             # 全部 19 個有 device/order 的 target
NETDEV = 'device!~"lo|veth.*|docker.*|br-.*|tap.*|fwbr.*|fwln.*|fwpr.*|vmbr.*|gvmbr.*"'  # 注意: 此 device 是網卡名, 非我們的 target label
FSX = 'fstype!~"tmpfs|overlay|squashfs|ramfs|devtmpfs|fuse.*|iso9660"'

# ★ panel id 是流水號(nid 依組裝順序遞增)。portal 0.7.0 起嵌入 d-solo
#   panelId=3/4/5/6(四 bargauge)與 13/14(CPU/記憶體趨勢)——面板「順序或增刪」
#   會重編號,必須同步 portal/frontend/src/pages/Devices.tsx 的 panelId。
_id = [0]
def nid():
    _id[0] += 1; return _id[0]

def srt(expr):
    return f'sort_by_label({expr}, "order")'

def pct_thr():
    return {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}

def temp_thr():
    return {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "yellow", "value": 60}, {"color": "red", "value": 75}]}

def tgt(expr, ref="A", instant=False, fmt="time_series", legend="{{device}}"):
    t = {"datasource": DS, "expr": expr, "refId": ref, "instant": instant, "range": not instant, "format": fmt}
    if legend is not None:
        t["legendFormat"] = legend
    return t

def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}

def bargauge(title, expr, x, y, w, h, unit="percent", maxv=100, thr=None):
    return {"id": nid(), "type": "bargauge", "title": title, "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": [tgt(srt(expr), "A", instant=True)],
            "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True, "valueMode": "color",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "fieldConfig": {"defaults": {"unit": unit, "min": 0, "max": maxv, "thresholds": thr or pct_thr()}, "overrides": []}}

def stat(title, expr, x, y, w, h):
    return {"id": nid(), "type": "stat", "title": title, "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": [tgt(expr, "A", instant=True, legend=None)],
            "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center",
                        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
            "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"mode": "absolute",
                            "steps": [{"color": "red", "value": None}, {"color": "green", "value": 11}]}}, "overrides": []}}

def timeseries(title, expr, x, y, w, h, unit="percent", legend="{{device}}"):
    return {"id": nid(), "type": "timeseries", "title": title, "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": [tgt(srt(expr), "A", legend=legend)],
            "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "max"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}},
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 8, "showPoints": "never"}},
                            "overrides": []}}

def statetimeline(title, expr, x, y, w, h, legend="{{device}}"):
    return {"id": nid(), "type": "state-timeline", "title": title, "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": [tgt(srt(expr), "A", legend=legend)],
            "options": {"mergeValues": True, "showValue": "never", "alignValue": "center", "rowHeight": 0.9,
                        "legend": {"displayMode": "list", "placement": "bottom"}},
            "fieldConfig": {"defaults": {
                "mappings": [{"type": "value", "options": {"1": {"text": "在線", "color": "green", "index": 0},
                                                            "0": {"text": "離線", "color": "red", "index": 1}}}],
                "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]},
                "color": {"mode": "thresholds"}}, "overrides": []}}

def overview_table(x, y, w, h):
    metrics = [
        ("A", f'up{{{NODE}}}'),  # keeps device+order+instance
        ("B", f'100 - (avg by(device,order)(rate(node_cpu_seconds_total{{mode="idle",{NODE}}}[5m])) * 100)'),
        ("C", f'(1 - sum by(device,order)(node_memory_MemAvailable_bytes{{{NODE}}}) / sum by(device,order)(node_memory_MemTotal_bytes{{{NODE}}})) * 100'),
        ("D", f'max by(device,order)((1 - node_filesystem_avail_bytes{{{NODE},{FSX}}} / node_filesystem_size_bytes) * 100)'),
        ("E", f'sum by(device,order)(node_load1{{{NODE}}})'),
        ("G", f'max by(device,order)(node_hwmon_temp_celsius{{{NODE}}})'),
        ("F", f'sum by(device,order)(node_time_seconds{{{NODE}}} - node_boot_time_seconds{{{NODE}}})'),
    ]
    tgts = [tgt(e, r, instant=True, fmt="table", legend=None) for r, e in metrics]
    rename = {"device": "設備", "order": "排序", "instance": "位址", "Value #A": "狀態", "Value #B": "CPU %",
              "Value #C": "記憶體 %", "Value #D": "磁碟 %", "Value #E": "負載(1m)", "Value #G": "溫度", "Value #F": "開機時長"}
    order = {"設備": 0, "位址": 1, "狀態": 2, "CPU %": 3, "記憶體 %": 4, "磁碟 %": 5, "負載(1m)": 6, "溫度": 7, "開機時長": 8, "排序": 9}
    pctcol = lambda n: {"matcher": {"id": "byName", "options": n}, "properties": [
        {"id": "unit", "value": "percent"}, {"id": "decimals", "value": 0}, {"id": "thresholds", "value": pct_thr()},
        {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "gradient"}}]}
    return {"id": nid(), "type": "table", "title": "設備總覽表", "datasource": DS,
            "gridPos": {"h": h, "w": w, "x": x, "y": y}, "targets": tgts,
            "transformations": [
                {"id": "joinByField", "options": {"byField": "device", "mode": "outer"}},
                {"id": "organize", "options": {
                    "excludeByName": {**{f"Time{s}": True for s in ["", " 1", " 2", " 3", " 4", " 5", " 6", " 7"]},
                                      **{f"order {i}": True for i in range(1, 8)},  # joinByField 後各查詢殘留的 order 欄
                                      "__name__": True, "job": True},
                    "renameByName": rename, "indexByName": order}}],
            "fieldConfig": {"defaults": {"custom": {"align": "center", "cellOptions": {"type": "auto"}}}, "overrides": [
                {"matcher": {"id": "byName", "options": "排序"}, "properties": [{"id": "custom.hidden", "value": True}]},
                {"matcher": {"id": "byName", "options": "設備"}, "properties": [
                    {"id": "custom.align", "value": "left"}, {"id": "custom.width", "value": 130}]},
                {"matcher": {"id": "byName", "options": "位址"}, "properties": [{"id": "custom.align", "value": "left"}]},
                {"matcher": {"id": "byName", "options": "狀態"}, "properties": [
                    {"id": "mappings", "value": [{"type": "value", "options": {
                        "1": {"text": "● 在線", "color": "green", "index": 0}, "0": {"text": "✕ 離線", "color": "red", "index": 1}}}]},
                    {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
                pctcol("CPU %"), pctcol("記憶體 %"), pctcol("磁碟 %"),
                {"matcher": {"id": "byName", "options": "負載(1m)"}, "properties": [{"id": "unit", "value": "short"}, {"id": "decimals", "value": 2}]},
                {"matcher": {"id": "byName", "options": "溫度"}, "properties": [
                    {"id": "unit", "value": "celsius"}, {"id": "decimals", "value": 0}, {"id": "thresholds", "value": temp_thr()},
                    {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
                {"matcher": {"id": "byName", "options": "開機時長"}, "properties": [{"id": "unit", "value": "s"}, {"id": "decimals", "value": 0}]}]},
            "options": {"showHeader": True, "sortBy": [{"displayName": "排序", "desc": False}]}}

# 高度設計:11 台 node 免滾動 — bargauge/stat h=13、表格 h=14(11列+表頭)、
# statetimeline h=12(19 target)、timeseries h=12(右側圖例表 11 列全顯)
P = []
P.append(row("即時概況", 0))
P.append(stat("在線設備數", f'sum(up{{{NODE}}})', 0, 1, 4, 13))
P.append(bargauge("各設備 CPU 使用率", f'100 - (avg by(device,order)(rate(node_cpu_seconds_total{{mode="idle",{NODE}}}[5m])) * 100)', 4, 1, 5, 13))
P.append(bargauge("各設備 記憶體使用率", f'(1 - sum by(device,order)(node_memory_MemAvailable_bytes{{{NODE}}}) / sum by(device,order)(node_memory_MemTotal_bytes{{{NODE}}})) * 100', 9, 1, 5, 13))
P.append(bargauge("各設備 磁碟使用率(最滿掛載)", f'max by(device,order)((1 - node_filesystem_avail_bytes{{{NODE},{FSX}}} / node_filesystem_size_bytes) * 100)', 14, 1, 5, 13))
P.append(bargauge("各設備 溫度", f'max by(device,order)(node_hwmon_temp_celsius{{{NODE}}})', 19, 1, 5, 13, unit="celsius", maxv=90, thr=temp_thr()))

P.append(row("設備總覽", 14))
P.append(overview_table(0, 15, 24, 14))

P.append(row("服務 / 目標存活狀態", 29))
P.append(statetimeline("Prometheus 監控目標 (19)", f'up{{{ALL}}}', 0, 30, 12, 12, legend="{{device}}"))
P.append(statetimeline("OpenWrt 服務 (9)", "openwrt_service_up", 12, 30, 12, 12, legend="{{service}}"))

P.append(row("趨勢 (預設 6 小時)", 42))
P.append(timeseries("CPU 使用率", f'100 - (avg by(device,order)(rate(node_cpu_seconds_total{{mode="idle",{NODE}}}[5m])) * 100)', 0, 43, 12, 12, "percent"))
P.append(timeseries("記憶體使用率", f'(1 - sum by(device,order)(node_memory_MemAvailable_bytes{{{NODE}}}) / sum by(device,order)(node_memory_MemTotal_bytes{{{NODE}}})) * 100', 12, 43, 12, 12, "percent"))
P.append(timeseries("網路接收流量", f'sum by(device,order)(rate(node_network_receive_bytes_total{{{NODE},{NETDEV}}}[5m]))', 0, 55, 12, 12, "Bps"))
P.append(timeseries("網路傳送流量", f'sum by(device,order)(rate(node_network_transmit_bytes_total{{{NODE},{NETDEV}}}[5m]))', 12, 55, 12, 12, "Bps"))
P.append(timeseries("磁碟讀取速率", f'sum by(device,order)(rate(node_disk_read_bytes_total{{{NODE}}}[5m]))', 0, 67, 12, 12, "Bps"))
P.append(timeseries("磁碟寫入速率", f'sum by(device,order)(rate(node_disk_written_bytes_total{{{NODE}}}[5m]))', 12, 67, 12, 12, "Bps"))
P.append(timeseries("Swap 使用量", f'sum by(device,order)(node_memory_SwapTotal_bytes{{{NODE}}} - node_memory_SwapFree_bytes{{{NODE}}})', 0, 79, 12, 12, "bytes"))
P.append(timeseries("溫度", f'max by(device,order)(node_hwmon_temp_celsius{{{NODE}}})', 12, 79, 12, 12, "celsius"))

dash = {"uid": "homelab-overview", "title": "設備總覽 (Homelab)", "tags": ["homelab", "overview", "中文"],
        "timezone": "Asia/Taipei", "editable": True, "refresh": "30s", "schemaVersion": 39, "version": 1,
        "time": {"from": "now-6h", "to": "now"}, "templating": {"list": []}, "annotations": {"list": []}, "panels": P}
print(json.dumps(dash, ensure_ascii=False, indent=2))
