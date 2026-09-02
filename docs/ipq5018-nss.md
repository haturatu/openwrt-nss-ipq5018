# IPQ5018 NSS bring-up design

このリポジトリは、`qosmio/openwrt-ipq` の `25.12-nss` を基礎に、公式
OpenWrt `openwrt-25.12` の先端へ追従したIPQ5018 NSS bring-up用の作業ツリーです。
NSS関連コードとfirmwareはOpenWrt upstreamには含まれないため、qosmioの
`nss-packages` feedを固定して利用します。

## 2026-09-02時点の実測

対象機は純正firmwareではなく、公式OpenWrt 25.12.5を起動しています。

| 項目 | 実測値 |
| --- | --- |
| model | Linksys MX2000 |
| compatible | `linksys,mx2000`, `qcom,ipq5018` |
| OpenWrt | 25.12.5 / r33051-f5dae5ece4 |
| Linux | 6.12.94 |
| target | `qualcommax/ipq50xx` |
| Ethernet dataplane | `qca_nss_dp` と `qca_ssdk` がロード済み |
| NSS core | `qca_nss_drv` は未ロード |
| ECM | `qca_nss_ecm` は未ロード |
| NSS firmware | `/lib/firmware/qca-nss*.bin` は未配置 |
| 外部switch | QCA8337、CPU port 6、SGMII固定1Gbps |
| NSS-DP | `dp2`、register `0x39d00000`、GIC SPI 141、Linux IRQ 43 |

現在のOpenWrt DTには `dp2` とQCA8337の経路がある一方、NSS core用の
`nss-common`/`nss0`と、firmware load用の`nss_region`はありません。これは
現行公式イメージがNSS-DPまでで、NSS core/ECMを組み込んでいないためです。

現在の設定ではOpenWrt標準のsoftware/hardware flow offloadは無効です。NSSの
測定時もこの状態を維持し、NSSと標準flow offloadの二重適用を避けます。

## 採用した構成

```text
official openwrt-25.12
        |
        +-- qosmio NSS kernel/mac80211 patches
        +-- IPQ5018 NSS DT and reserved memory
        +-- nss-packages:NSS-12.5-K6.x
        |
        +-- MX2000
             dp2 -- SGMII -- QCA8337 CPU port 6 -- WAN/LAN
```

NSS firmwareは最初のbring-upでは11.4を選びます。IPQ5018用のmedium memory
profile、firmware load address `0x40000000`、16 MiBのno-map reserved memoryは
qosmio側のIPQ5018定義を使用します。これらはQSDK由来の非upstream仕様なので、
firmwareの起動ログが取れるまで「動作済み」とは扱いません。

初期seedでは `ATH11K_NSS_SUPPORT` を無効化します。2.4 GHz/5 GHzのath11kを
通常経路で動かしたまま、NSS core、NSS-DP、ECM NAT44を分離して検証するためです。
Wi-Fi NSSはNSS-DPとECMが安定した後の別フェーズで有効化します。

## 実装レイヤ

1. `target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq5018-nss.dtsi`
   - IPQ5018 NSS0、clock、IRQ、load address、機能フラグを定義。
2. `target/linux/qualcommax/patches-6.12/*ipq5018*reserved-memory*`
   - firmware領域 `0x40000000..0x41000000` をLinuxから予約。
3. `target/linux/qualcommax/Makefile`
   - qualcommaxの標準パッケージへNSS driver/ECM/bridge managerを追加。
4. `feeds.conf.default`
   - `qosmio/nss-packages` の `NSS-12.5-K6.x` を利用。
5. `nss-setup/config-ipq5018.seed`
   - MX2000を含むIPQ5018向けの再現可能な初期構成。

## 検証段階

### Phase 0: baseline

NSSを有効にしない公式OpenWrt相当で、起動、WAN/LAN、QCA8337、2.4 GHz、5 GHz、
sysupgrade、dual partitionを確認します。

### Phase 1: NSS core

`nss-firmware-ipq50xx` と `kmod-qca-nss-drv`を有効にし、次を確認します。

```text
dmesg | grep -Ei 'nss|firmware|qca'
cat /proc/iomem
cat /proc/interrupts
cat /proc/modules
```

期待値はfirmware load、NSS core 0 initialized、driver probe完了です。失敗時は
reserved memory、load address、clock/reset、IRQ、firmware ABIの順に切り分けます。

### Phase 2: NSS-DP and QCA8337

`dp2`をQCA8337 uplinkとして扱い、WAN/LANのリンク、VLANなしのIPv4 forwarding、
iperf3の双方向通信を確認します。`dp2`を物理WANと誤認してネットワーク構成を
変更しません。

### Phase 3: ECM NAT44

IPv4 TCP/UDPのroutingとNAT44だけを対象にECM offloadを有効化します。accelerated
connection数とNSS statisticsが増え、CPU負荷が下がることを確認します。

### Phase 4以降

IPv6、bridge/VLAN、PPPoE、SQM、最後にath11k Wi-Fi NSSを個別に追加します。
機能を一度に複数有効化しません。

## 更新運用

```text
origin   git@github.com:haturatu/openwrt-nss-ipq5018.git  (private)
qosmio   https://github.com/qosmio/openwrt-ipq.git
upstream https://github.com/openwrt/openwrt.git
```

通常の更新は公式OpenWrtを基底にします。

```sh
git fetch upstream openwrt-25.12
git fetch qosmio 25.12-nss
git rebase upstream/openwrt-25.12
```

NSS差分が競合する場合は、公式側の変更を優先してから、NSS kernel patch、
IPQ5018 DT、MX2000 device profileの順に再検証します。NSS firmware packageは
別feedのrevisionも記録し、driverとのABI不一致を避けます。

## 現時点の判定

MX2000の通常OpenWrt対応とNSS-DP/QCA8337経路は確認済みです。NSS core/ECMの実機
bring-upは、このブランチのビルドイメージを実機へ導入してから判定します。現時点
では、NSS対応「実装済み・未検証」とし、完成済みとは記載しません。
