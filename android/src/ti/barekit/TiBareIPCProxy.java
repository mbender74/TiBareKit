package ti.barekit;

import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.KrollFunction;
import org.appcelerator.kroll.KrollDict;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.titanium.TiBlob;
import to.holepunch.bare.kit.IPC;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import android.os.Handler;
import android.os.Looper;

@Kroll.proxy(creatableInModule = TiBareKitModule.class, name = "IPC")
public class TiBareIPCProxy extends KrollProxy {
  private static final String LCAT = "TiBareIPCProxy";
  private IPC ipc;
  private KrollFunction readableCb;
  private KrollFunction writableCb;

  public TiBareIPCProxy() {
    super();
  }

  @Kroll.method
  public void handleCreationDict(KrollDict options) {
    super.handleCreationDict(options);
    Object workletArg = (options != null) ? options.get("worklet") : null;
    if (workletArg instanceof TiBareWorkletProxy) {
      ipc = new IPC(((TiBareWorkletProxy) workletArg).getWorklet());
    }
  }

  // `new IPC(worklet)` passes the worklet proxy as args[0], NOT a dict. The base
  // KrollProxy.handleCreationArgs early-returns when args[0] is not a HashMap,
  // so handleCreationDict never runs and `ipc` stays null. Override to detect
  // the bare-worklet-arg case and construct the native IPC directly. Mirrors the
  // idiomatic Titanium pattern (titanium_mobile BufferProxy.handleCreationArgs).
  @Override
  public void handleCreationArgs(org.appcelerator.kroll.KrollModule createdInModule, Object[] args) {
    if (args != null && args.length > 0 && args[0] instanceof TiBareWorkletProxy) {
      ipc = new IPC(((TiBareWorkletProxy) args[0]).getWorklet());
      return;
    }
    super.handleCreationArgs(createdInModule, args);
  }

  private ByteBuffer toBuffer(Object payload) {
    if (payload == null) return null;
    byte[] bytes;
    if (payload instanceof TiBlob) {
      bytes = ((TiBlob) payload).getBytes();
    } else if (payload instanceof String) {
      bytes = ((String) payload).getBytes(StandardCharsets.UTF_8);
    } else {
      return null;
    }
    ByteBuffer buf = ByteBuffer.allocateDirect(bytes.length);
    buf.put(bytes);
    buf.flip();
    return buf;
  }

  @Kroll.setProperty @Kroll.method
  public void setReadable(KrollFunction cb) {
    readableCb = cb;
    if (ipc == null) return;
    ipc.readable(() -> {
      if (readableCb != null) {
        new Handler(Looper.getMainLooper()).post(() ->
          readableCb.call(getKrollObject(), new Object[] { this }));
      }
    });
  }

  @Kroll.setProperty @Kroll.method
  public void setWritable(KrollFunction cb) {
    writableCb = cb;
    if (ipc == null) return;
    ipc.writable(() -> {
      if (writableCb != null) {
        new Handler(Looper.getMainLooper()).post(() ->
          writableCb.call(getKrollObject(), new Object[] { this }));
      }
    });
  }

  @Kroll.method
  public Object read(Object... args) {
    if (args != null && args.length > 0 && args[0] instanceof KrollFunction) {
      KrollFunction cb = (KrollFunction) args[0];
      if (ipc == null) return null;
      ipc.read((data, error) -> {
        KrollDict result = new KrollDict();
        if (error != null) {
          result.put("error", error.getMessage());
        } else if (data != null) {
          byte[] bytes = new byte[data.remaining()];
          data.get(bytes);
          result.put("data", TiBlob.blobFromData(bytes));
        }
        new Handler(Looper.getMainLooper()).post(() ->
          cb.call(getKrollObject(), new Object[] { result }));
      });
      return null;
    }
    if (ipc == null) return null;
    ByteBuffer data = ipc.read();
    if (data == null) return null;
    byte[] bytes = new byte[data.remaining()];
    data.get(bytes);
    return TiBlob.blobFromData(bytes);
  }

  @Kroll.method
  public int write(Object... args) {
    if (args == null || args.length == 0) return 0;
    Object payload = args[0];
    ByteBuffer buf = toBuffer(payload);
    if (buf == null) return 0;
    if (ipc == null) return 0;
    if (args.length > 1 && args[1] instanceof KrollFunction) {
      KrollFunction cb = (KrollFunction) args[1];
      ipc.write(buf, error -> {
        KrollDict result = new KrollDict();
        if (error != null) {
          result.put("error", error.getMessage());
        }
        new Handler(Looper.getMainLooper()).post(() ->
          cb.call(getKrollObject(), new Object[] { result }));
      });
      return 0;
    }
    return ipc.write(buf);
  }

  @Kroll.method
  public void close() {
    if (ipc != null) {
      ipc.close();
    }
  }
}