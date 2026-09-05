# MX2000 Wi-Fi NSS 調査（2026-09-05）

対象: `root@192.168.1.1`、`feat/nss-ipq5018-autoload-wifi`（調査開始 HEAD: `a8bde97c62`）。
`ls -ltr /tmp` で既存調査・ビルドログを確認後、SSH の読み取りと GitHub Actions のログ、ローカルソースを照合した。

## 現在の実機で確認した事実

- Linux 6.12.103、release `r0-8bbd3fa`。
- `boot_part=2`、cmdline は `ubi.mtd=alt_rootfs`。過去の「primary を起動している」という説明は現在には当てはまらない。
- ath11k の `nss_offload` パラメーターが存在せず、`frame_mode=1`。
- `/etc/modules.d/ath11k`、`/etc/config/pbuf`、`/etc/ipq_release` が存在しない。
- `/rom/lib/modules/6.12.103/ath11k.ko` と実行側ファイルは同じ SHA-256:
  `174dfdafef87caa578dca535b5b182ecab0d13c00cca0eb079c70bc5edbc35a7`（772600 bytes）。
- qca_nss_drv、qca_nss_dp、ecm はロード済み。NSS drv の送受信・status sync カウンターには値がある。
- IPv4/IPv6 の create_requests、RX/TX は取得時点でゼロ。
- 初回 dmesg に `phy1-ap0`、`wan` の `ae_ifnum=-1` と `rule-rejected ... reason=invalid-interface` がある。
- MemTotal は 425920 kB、初回 MemAvailable は約 210 MB。これだけでは 256M/512M プロファイルの可否は判定できない。

したがって、現在起動中のイメージは Wi-Fi NSS 用 ath11k を備えていない。
設定ファイルや module parameter の追加だけでは解決しない。NSS コアの活動は Wi-Fi/NAT 加速成功の証拠にはならない。
WAN 側の ifnum=-1 は Wi-Fi ドライバーと別途検証する必要があり、今回の観測だけではその原因を確定できない。

実機取得ログ: `/tmp/ipq5018-wifi-nss-runtime-20260905.log`。
既存の過去レポートは履歴資料であり、今回の起動先やモジュール確認を優先する。

## 現行 CI の直接の阻害要因

[Wi-Fi NSS matrix run 33955024227](https://github.com/haturatu/openwrt-nss-ipq5018/actions/runs/33955024227) は 256M/512M とも失敗。
256M のログから次の原因を直接確認した:

```text
patch: **** malformed patch at line 10: @@ -1878,7 +1880,8 @@ static int ath11k_nss_init(struct ath11k_base *ab)
package/kernel/mac80211/compile ... Error 2
```

`999-908-ath11k-trace-ipq5018-wifili-interface-allocation.patch` の両 hunk の行数が本文と不一致だった。
第一 hunk は old=4/new=6、第二 hunk は old=6/new=7 が正しい。
ローカルでヘッダーを訂正し、backports-6.18.39 の nss.c のコピーに `patch --batch --fuzz=0 -p1` で適用成功。
二つの診断ログの挿入と `git diff --check` を確認した。完全な firmware build と実機での NSS 有効動作は未検証。

通常ビルド [33955023746](https://github.com/haturatu/openwrt-nss-ipq5018/actions/runs/33955023746) の成功とは区別する。
`.github/workflows/ipq5018.yml` の push ビルドは `inputs.wifi_nss` がなく false になる。
Wi-Fi matrix または workflow_dispatch の `wifi_nss=true` で生成された成果物が必要。
release の Git revision だけではビルド設定や成果物を特定できない。

## 対応と実機判定の順序

1. 修正パッチを含む HEAD で Wi-Fi matrix を実行し、256M/512M の成功・失敗を別々に確認する。
   手動起動するなら `ipq5018.yml` の `wifi_nss=true` と `wifi_nss_mem_profile=256` または `512` を明示する。
2. build-metadata の `wifi_nss=true`、profile、commit とイメージ SHA-256 を照合する。
   最終 rootfs 内の ath11k に `nss_offload` があり、pbuf、autoload 設定、Wi-Fi 対応 NSS driver が含まれることを確認する。
3. 通常 ath11k と NSS 版のモジュールだけを混在させず、整合したイメージで検証する。
   今回はフラッシュ、boot_part 書換え、再起動、Wi-Fi 再起動は実行していない。
4. 起動後に次を確認する:

```sh
cat /proc/cmdline
fw_printenv boot_part
cat /sys/module/ath11k/parameters/nss_offload  # 1
cat /sys/module/ath11k/parameters/frame_mode   # 2
cat /etc/modules.d/ath11k
cat /etc/config/pbuf
dmesg | grep -Ei 'ath11k|WIFILI|nss|pbuf'
```

5. IPQ5018 は target_type=29/internal interface、QCN6122 は target_type=30/external interface を選ぶ実装。
   `999-907` に対応があり、QCN6122 用 DTS overlay は helper が有効化する。
   修正した `999-908` のログで実際の target_type/if_num/userpd_id を確認する。
   割当失敗なら NSS driver の WIFIOFFLOAD、external interface、DTS priority を調べる。
   その前後でのメモリー割当失敗・firmware crash の有無を確認して profile を比較する。
6. radio/AP が安定した後に ECM を検証する。Wi-Fi 端末から WAN 側の試験先への転送で、
   NSS Wi-Fi 統計、IPv4/IPv6 create_requests と RX/TX、ECM 加速件数の増加を確認する。
   router 自身を終端にした通信だけでは転送加速の確認にならない。
   WAN の ifnum が負のままなら DSA conduit の解決ログと登録順を別途追う。

初回ログは ECM の高頻度出力が多く、起動時ログが残っていなかった。
次回は起動直後のログを保存し、NSS 成功を古い dmesg メッセージの有無だけで判定しないこと。
