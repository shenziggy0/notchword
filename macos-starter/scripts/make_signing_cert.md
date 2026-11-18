# 发布签名准备

发布构建使用一个长期稳定的代码签名身份，以及独立的 Sparkle EdDSA 更新密钥。

1. 在「钥匙串访问 → 证书助理 → 创建证书」中创建自签名的代码签名证书。记录证书名称，用钥匙串导出加密的备份并离线保管。
2. 在 macos-starter 下运行 bash scripts/fetch_sparkle.sh，脚本会校验官方 Sparkle 发行包。用 scripts/.cache/sparkle-2.9.6/bin/generate_keys --account notchword 建立更新密钥，保存它显示的公钥。更新私钥留在钥匙串。使用该工具的导出功能离线备份私钥。
3. 设置 EW_SIGN_IDENTITY、EW_SU_PUBLIC_ED_KEY、EW_SU_FEED_URL 和 EW_RELEASE_DOWNLOAD_URL。feed 与最终 DMG 地址使用 HTTPS。
4. 设置 EW_BUILD_VERSION 和数值递增的 EW_BUILD_NUMBER，然后运行 bash release.sh。
5. 先用独立 feed 检查 A→B 两版本升级。记录安装前后的辅助功能、屏幕录制、自动化、Keychain 和开机启动状态。确认安装提示后再发布 DMG、SHA-256 与 appcast 条目。

自签名构建不会获得 Apple 公证。首次安装提示和权限迁移依系统版本与设备而异，应在新 Mac 上验收。
