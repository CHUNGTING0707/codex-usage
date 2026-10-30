# Codex Usage Widget

第一次使用前，請雙擊 `Connect-CodexAccount.cmd`，在瀏覽器中完成一次 Codex CLI 的 ChatGPT 登入。連線程式會自動選用最新的 Desktop 內建 CLI，避免不同版本的登入狀態不一致。Desktop App 的登入狀態不會自動授權給其他程式。

完成後，雙擊 `Start-CodexUsageWidget.exe` 啟動；它帶有自訂 icon，且不會留下命令提示字元視窗。`.vbs` 與 `.cmd` 為相容性啟動器。

它會在右下角建立一個永遠置頂的用量小窗，每 120 秒以本機 `codex app-server` 的唯讀 `account/rateLimits/read` 查詢更新。此操作不會傳送模型提示或消耗 Codex 額度，也不需要 API Key。

可拖曳卡片移動；右上角 `×` 關閉；`Refresh` 可手動更新。

如需改更新頻率，請在 PowerShell 執行：

```powershell
.\CodexUsageWidget.ps1 -RefreshSeconds 300
```

若未完成連線，卡片會顯示連線錯誤而不會顯示任何用量。可直接關閉並先執行連線腳本。

## Claude 用量

### 官方剩餘 %（優先使用）

如果這台電腦已用 Claude Code 命令列工具登入過（`%USERPROFILE%\.local\bin\claude.exe`，執行一次並登入即可），小工具會用這份登入資訊（`%USERPROFILE%\.claude\.credentials.json`）向 Anthropic 查詢官方用量。數字和 Claude「設定 → 用量」頁面一致，共用帳號裡所有人的用量都算在內；這種情況下「校準」按鈕會自動隱藏。

- 查詢用量本身不會傳送提示詞，也不消耗 Claude 額度；只有約每 8 小時換新登入時，會送出一個極小的 Haiku 請求（見下一點）。
- 登入 token 大約 8 小時過期一次。過期時小工具會在背景呼叫 Claude Code 命令列工具，送出一個只回「ok」的 Haiku 請求，讓它自動換新登入（會用掉極少量額度）。如果換新失敗，請執行一次 `claude`；仍失敗就在裡面輸入 `/login` 重新登入。
- 這個查詢方式不是 Anthropic 公開文件寫明的，之後可能會改變。查詢失敗時，小工具會自動改用下面的本機估算，狀態列會以 `Estimate -` 開頭；把滑鼠移到狀態列上可以看到失敗原因，同樣的內容也會記在程式旁的 `ClaudeUsage.log`。

### 本機估算（無法查到官方用量時）

本機估算的來源是這台電腦的對話紀錄 `%USERPROFILE%\.claude\projects\*.jsonl`：只讀本機檔案，不連網、不使用登入資訊，也不消耗 Claude 額度。

- **5小時用量**：目前這個 5 小時區段的 token 數（從該區段第一則訊息的整點開始算），下方顯示距離重置還有多久。
- **1週用量**：從 Claude 每週重置時間起算的 token 數。重置時間寫在 `ClaudeUsageConfig.json` 的 `weeklyResetDayOfWeek`（0 = 週日 … 6 = 週六）和 `weeklyResetHour`（本地時間，0–23），請照 Claude 用量頁面「每週限制」顯示的時間填；設為 -1 則改算最近 7 天。
- 計算方式為 input + cache 寫入 + output，不含 cache 讀取；同一則回覆的重複紀錄會自動去除。
- 只統計這台電腦上 Claude Code／Claude Desktop Code 分頁的使用量，claude.ai 網頁版或其他裝置的用量不會算進來。

### 改用剩餘 % 顯示（校準）

Claude 沒有公開各方案的 token 上限，所以還沒校準之前只會顯示「已用多少」。校準一次之後就會改顯示剩餘 %：

1. 打開 Claude 的「設定 → 用量」頁面，看目前 5 小時、每週各用了幾 %。
2. 按小工具上的「校準」，依序填入這兩個 %（不想校準的那一項留空）。
3. 小工具會用「本機已用的 token ÷ 你填的 %」算出上限，存進 `ClaudeUsageConfig.json`，之後就以剩餘 % 顯示。

如果你也會在 claude.ai 網頁版或手機上使用 Claude，那些用量不會出現在本機紀錄裡，% 會慢慢不準，再按一次「校準」就好。想恢復成顯示 token 數，把 `ClaudeUsageConfig.json` 裡的數字改回 0。
