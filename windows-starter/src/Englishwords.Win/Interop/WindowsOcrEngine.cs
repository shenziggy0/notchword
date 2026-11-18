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
        var lang = new Language("en-US");
        return OcrEngine.IsLanguageSupported(lang);
    }

    public async Task<string> RecognizeRegionAsync(Int32Rect physicalRect, long requestId, CancellationToken cancellationToken)
    {
        if (physicalRect.Width < 8 || physicalRect.Height < 8)
        {
            return string.Empty;
        }

        var lang = new Language("en-US");
        var engine = OcrEngine.TryCreateFromLanguage(lang)
            ?? throw new InvalidOperationException("系统未安装英文 (en-US) OCR 语言包，请在 Windows 设置 → 时间和语言中添加英语。");

        cancellationToken.ThrowIfCancellationRequested();

        using var bitmap = new Bitmap(physicalRect.Width, physicalRect.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen(physicalRect.X, physicalRect.Y, 0, 0, new System.Drawing.Size(physicalRect.Width, physicalRect.Height));
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (!IsCurrentRequest(requestId)) throw new OperationCanceledException();

        var softwareBitmap = ConvertToSoftwareBitmap(bitmap);
        using (softwareBitmap)
        {
            var result = await engine.RecognizeAsync(softwareBitmap).AsTask(cancellationToken).ConfigureAwait(false);
            if (!IsCurrentRequest(requestId)) throw new OperationCanceledException();
            return result.Text?.Trim() ?? string.Empty;
        }
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
                BitmapAlphaMode.Premultiplied);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }
}
