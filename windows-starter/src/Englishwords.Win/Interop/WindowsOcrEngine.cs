using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Englishwords.Win.Interop;

/// <summary>
/// 基于 <see cref="OcrEngine"/> (<c>Windows.Media.Ocr</c>) 的屏幕区域文字识别器。
/// </summary>
public sealed class WindowsOcrEngine
{
    private long _regionRequestId;

    public long NextRequestId() => Interlocked.Increment(ref _regionRequestId);

    public void InvalidatePending() => Interlocked.Increment(ref _regionRequestId);

    public bool IsCurrentRequest(long requestId) => Interlocked.Read(ref _regionRequestId) == requestId;

    public static bool IsEnglishOcrAvailable()
    {
        try
        {
            var lang = new Language("en-US");
            return OcrEngine.IsLanguageSupported(lang);
        }
        catch
        {
            // 缺少 OCR 组件或系统版本不支持时只降级为不可用，不能把调用方带崩。
            return false;
        }
    }

    public async Task<string> RecognizeRegionAsync(
        Int32Rect physicalRect,
        long requestId,
        CancellationToken cancellationToken,
        Action? onCaptured = null)
    {
        if (physicalRect.Width < 8 || physicalRect.Height < 8)
        {
            return string.Empty;
        }

        // 建引擎、抓屏与像素转换都是同步阻塞调用，全部放在后台线程，避免卡住 WPF UI 线程。
        var (engine, softwareBitmap) = await Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();

            var lang = new Language("en-US");
            var ocrEngine = OcrEngine.TryCreateFromLanguage(lang)
                ?? throw new InvalidOperationException("系统未安装英文 (en-US) OCR 语言包，请在 Windows 设置 → 时间和语言中添加英语。");

            cancellationToken.ThrowIfCancellationRequested();

            using var bitmap = CapturePhysicalRect(physicalRect);
            var captured = ConvertToSoftwareBitmap(bitmap);

            // 截屏已完成，调用方可在此刻才展示 Loading 面板，避免自家面板被截进图里。
            onCaptured?.Invoke();

            return (ocrEngine, captured);
        }, cancellationToken).ConfigureAwait(false);

        using (softwareBitmap)
        {
            if (!IsCurrentRequest(requestId)) throw new OperationCanceledException();

            var result = await engine.RecognizeAsync(softwareBitmap).AsTask(cancellationToken).ConfigureAwait(false);
            if (!IsCurrentRequest(requestId)) throw new OperationCanceledException();
            return result.Text?.Trim() ?? string.Empty;
        }
    }

    /// <summary>
    /// 抓取物理屏幕矩形。超过 <see cref="OcrEngine.MaxImageDimension"/> 时按比例缩小，否则 OCR 引擎会直接报错。
    /// </summary>
    private static Bitmap CapturePhysicalRect(Int32Rect physicalRect)
    {
        var width = Math.Max(1, physicalRect.Width);
        var height = Math.Max(1, physicalRect.Height);

        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen(
                physicalRect.X,
                physicalRect.Y,
                0,
                0,
                new System.Drawing.Size(width, height),
                CopyPixelOperation.SourceCopy);
        }

        var maxDimension = (int)OcrEngine.MaxImageDimension;
        if (maxDimension <= 0 || (width <= maxDimension && height <= maxDimension))
        {
            return bitmap;
        }

        var scale = Math.Min((double)maxDimension / width, (double)maxDimension / height);
        var targetWidth = Math.Max(1, (int)Math.Floor(width * scale));
        var targetHeight = Math.Max(1, (int)Math.Floor(height * scale));

        var scaled = new Bitmap(targetWidth, targetHeight, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(scaled))
        {
            graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            graphics.DrawImage(bitmap, 0, 0, targetWidth, targetHeight);
        }

        bitmap.Dispose();
        return scaled;
    }

    private static SoftwareBitmap ConvertToSoftwareBitmap(Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var byteCount = data.Stride * data.Height;
            var bytes = new byte[byteCount];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, byteCount);

            return SoftwareBitmap.CreateCopyFromBuffer(
                bytes.AsBuffer(),
                BitmapPixelFormat.Bgra8,
                bitmap.Width,
                bitmap.Height,
                // 抓屏结果没有预乘 alpha，用 Ignore 避免半透明边缘发黑。
                BitmapAlphaMode.Ignore);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }
}
