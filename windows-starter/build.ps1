param(
    [string]$Version = "0.5.2",
    [switch]$SelfContained
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

Write-Host "==> 运行核心领域层测试 (Englishwords.Core.Tests)"
dotnet test tests\Englishwords.Core.Tests\Englishwords.Core.Tests.csproj -c Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$PublishDir = Join-Path $Root "build\publish-win-x64"
$DistDir = Join-Path $Root "build\dist"
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$SelfContainedFlag = if ($SelfContained) { "true" } else { "false" }
Write-Host "==> 发布 Windows x64 客户端 (SelfContained=$SelfContainedFlag)"
dotnet publish src\Englishwords.Win\Englishwords.Win.csproj `
    -c Release `
    -r win-x64 `
    --self-contained $SelfContainedFlag `
    -o $PublishDir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ExePath = Join-Path $PublishDir "Englishwords.Win.exe"
Write-Host "==> 随包词库自检: --check-word unbelievable"
& $ExePath --check-word unbelievable
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$ZipName = "Englishwords-$Version-win-x64.zip"
$ZipPath = Join-Path $DistDir $ZipName
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path "$PublishDir\*" -DestinationPath $ZipPath

$Hash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$Hash  $ZipName" | Out-File -FilePath "$ZipPath.sha256" -Encoding ascii

Write-Host "==> 打包完成: $ZipPath"
