# Hardware keyboard toggle（Issue #332）

日期：2026-10-03。狀態：已實作；bundle、unit tests 與真實 guest 核心功能驗證通過。人工驗證限制見下文。

VM 視窗的 **Device → Use Hardware Keyboard** 提供勾選選單及 **⇧⌘K**。
勾選代表這個 VM 實際啟動時使用的 keyboard configuration。
選單要求先保存 guest 工作，再選 **Restart and Apply**。
取消不改動設定或 VM。套用會保存該 VM 的 `config.plist`，停止 VM，
再在同一個 `NSApplication` 內重建 VM 與視窗。PID 及 console streams 保持不變。
這是完整的 VM 重啟，不是 guest OS reboot，也不是即時 hot-plug。

關閉時，VM 使用 `keyboards = []`，並停止從 Mac keyboard
經 guest agent 轉送特殊鍵。開啟時恢復 `VZUSBKeyboardConfiguration`。
`hardwareKeyboardEnabled` 未出現在舊 manifest 時，維持原有的開啟狀態。
設定跟隨 VM。其他 VM 不受影響。

## Framework 限制與依據

Apple 的 [init(configuration:)，Parameters](https://developer.apple.com/documentation/virtualization/vzvirtualmachine/init(configuration:))
寫道：「The VM stores a copy of the configuration.」
這直接支持：修改建立 VM 前的 configuration，不能當作運行中 VM 已更新的證據。

Apple 的 [VZUSBDeviceConfiguration，Overview](https://developer.apple.com/documentation/virtualization/vzusbdeviceconfiguration)
寫道：「Classes that conform to this protocol represent hot-pluggable USB device configurations.」
同頁 Conforming Types 只列出 mass storage 與 passthrough configuration。
[VZUSBKeyboardConfiguration，Inherits From](https://developer.apple.com/documentation/virtualization/vzusbkeyboardconfiguration)
列出「VZKeyboardConfiguration」，Conforms To 沒有 `VZUSBDeviceConfiguration`。
根據兩頁及 macOS SDK 宣告推論：public USB hot-plug API 不適用於這個虛擬 keyboard。
因此實作使用完整 VM 重啟，沒有把忽略 key events 當作拔除 guest keyboard。

本機 macOS 27.0.1 framework 的 Objective-C method inventory 顯示 `_VZKeyboard`
有 `sendKeyEvents:`，但沒有 keyboard attach/detach selector。
這是本機版本的觀察，不是所有 macOS 版本或 private API 的保證。

## 驗證（2026-10-03）

環境：macOS 27.0.1 (26A434)、Xcode 27.0 RC、Swift 6.4、
真實 VPhone guest iOS 26.6.2 (23G90)。
測試使用官方 VM 的 APFS 副本及隔離 local bundle。

- 完整 `VPhone` Debug bundle build、`Bundle admission passed`、ad-hoc signature verification、Launchpad policy 與 Host preflight 均通過。
- `VPhoneCoreKitTests/ManifestTests`：10 tests 通過。涵蓋舊 manifest、開／關 plist round-trip、其他欄位更新及 guest device 更新時保留 preference。
- 官方 2.3.1 基線：Settings 搜尋欄已有 caret，但 software keyboard 沒有出現。
- 關閉後，系統 software keyboard 出現。點按 numeric keys 後，搜尋欄讀回輸入值。
- 開啟後，CUA 的原生 macOS `pressKey("a")` 經 window server 與 VM window，guest 搜尋欄讀回 `ㄇ`（注音輸入法）。
- 關閉時，host `a`、Delete、fn、Ctrl+Space、Esc 事件沒有改變搜尋文字或 keyboard layout。
- UI lifecycle 修正版完成關閉 → 開啟 → 關閉 → 開啟 → 關閉。最後交付 binary 再完成關閉 → 開啟 → 關閉及完全重新 launch。Host PID 在選單切換中保持，每次 guest 重啟後都取得新的 agent/UI read-back，選單與快捷鍵持續可操作。
- 實際讀取 AppKit `NSMenuItem.state` 及 Virtualization runtime keyboard array，log 原句依序包含 `[keyboard] Menu checked: false, active keyboards: 0`、`[keyboard] Menu checked: true, active keyboards: 1`。兩種狀態與保存設定相符。
- `Cancel` 保持 config SHA、Host PID 與 process 啟動時間不變。
- 完全停止並重新 launch VM 後，false 設定保留，software keyboard 再次出現並能點按輸入。

最後交付版的 VM binary SHA-256：
`aee60324dad1889c956397a57b0053c1a6575a034d28b934bfc8f8acd021dbc2`。
這個 binary 已通過關閉、開啟、再次關閉及重新 launch 的驗證。local bundle 的安裝 receipt、guest screenshot、UI tree 與 log 保留在本機驗證紀錄。

測試沒有執行 Flutter Golden tests。第三方 keyboard extension 的安裝或註冊不屬於本功能驗收。

## 限制

- 這個版本需要完整 VM restart。Public API 的限制見上述依據。未宣稱可以即時 hot-plug。
- 目前直接核對的是執行中的 AppKit menu state。CUA 未提供 menu checkmark 屬性，menu screenshot 無法取得，因此未直接核對畫面上的勾號像素。
- Mac keyboard 路徑使用原生 macOS 事件自動化驗證。沒有真人手按實體鍵盤的觀察紀錄。
- 實測僅涵蓋上述 host／guest 版本。其他 macOS 與 iPadOS guest 未測。

## 重現命令

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeBundle build
xcodebuild -project VPhoneKit/VPhoneKit.xcodeproj -scheme VPhoneCoreKitTests \
  -destination 'platform=macOS,arch=arm64' -only-testing:VPhoneCoreKitTests/ManifestTests test
```

在隔離 VM 開啟 Settings 搜尋欄。使用 **Device → Use Hardware Keyboard**，
分別取消及選擇 **Restart and Apply**。每次重啟後重新開啟搜尋欄，核對
software keyboard 點按輸入及 Mac keyboard 輸入。最後停止並重新 launch VM，
再核對選單 state、`config.plist` 與 guest 輸入。
