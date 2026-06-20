# TADA — 台灣科技農企業發展協會 數位資產

協會 AI 推廣計畫的數位成果集合。包含三個獨立的靜態網頁模組，皆為單檔 HTML，無建置步驟、無相依套件，可直接部署。

## 📦 模組

| 模組 | 路徑 | 說明 |
|------|------|------|
| 🌾 協會數位平台 | [`platform/`](platform/) | 最新消息、會員名錄、知識中心、Claude AI 助理整合平台 |
| 🎤 會長就職背板 | [`backdrop/`](backdrop/) | 黃仁勳風格就職典禮背板示意圖（Logo 牆 + 會長照片區） |
| ✉️ 電子邀請卡 | [`invitation/`](invitation/) | AI 賦能論壇暨就職典禮電子邀請卡 |

根目錄 [`index.html`](index.html) 為入口頁，連結至上述三個模組。

## 🚀 本地預覽

無需安裝任何套件，任選一種方式：

```bash
# 方式一：Python 內建伺服器
python3 -m http.server 8000
# 瀏覽 http://localhost:8000

# 方式二：Node（需先安裝 serve）
npx serve .
```

> 直接用瀏覽器開啟 `index.html` 也可以，但平台的 AI 助理需透過 http(s) 協定才能正常呼叫 API。

## 🌐 部署

### GitHub Pages
1. 推送本 repo 至 GitHub
2. Settings → Pages → Source 選 `main` 分支、根目錄 `/`
3. 數分鐘後即可透過 `https://<帳號>.github.io/<repo>/` 存取

### Vercel
1. Import 本 repo
2. Framework Preset 選 **Other**（純靜態，無需 build）
3. Deploy 完成

`vercel.json` 已預設好靜態託管設定。

## 🔑 AI 助理設定（platform 模組）

平台的 AI 助理透過 Anthropic API 運作。**請勿將 API Key 直接寫入前端原始碼**（會公開曝露）。建議做法：

- 部署時透過 Serverless Function（Vercel Function / Cloudflare Worker）代理 API 請求，Key 存於環境變數
- 詳見 [`docs/AI-SETUP.md`](docs/AI-SETUP.md)

## 📝 待辦 / 客製化

各模組中標示 `XX`、`某某`、佔位符之處，需替換為實際資料：

- **platform**：會員名單、理監事名單、活動日期、RSS 來源
- **backdrop**：會長照片、會員企業 Logo 與名稱
- **invitation**：活動日期、地點、報名 QR Code、聯絡方式

## 📂 結構

```
.
├── index.html          # 入口頁
├── platform/
│   └── index.html      # 協會數位平台
├── backdrop/
│   └── index.html      # 就職背板示意圖
├── invitation/
│   └── index.html      # 電子邀請卡
├── docs/
│   └── AI-SETUP.md     # AI 助理部署說明
├── vercel.json         # Vercel 靜態託管設定
├── .gitignore
├── LICENSE
└── README.md
```

## 📄 授權

本專案供台灣科技農企業發展協會內部使用，詳見 [LICENSE](LICENSE)。
