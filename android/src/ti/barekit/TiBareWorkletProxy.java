package ti.barekit;

import org.appcelerator.kroll.KrollProxy;
import org.appcelerator.kroll.KrollFunction;
import org.appcelerator.kroll.KrollDict;
import org.appcelerator.kroll.annotations.Kroll;
import org.appcelerator.titanium.TiBlob;
import org.appcelerator.titanium.TiApplication;
import to.holepunch.bare.kit.Worklet;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.io.InputStream;
import java.io.IOException;
import android.os.Handler;
import android.os.Looper;

@Kroll.proxy(creatableInModule = TiBareKitModule.class, name = "Worklet")
public class TiBareWorkletProxy extends KrollProxy {
  private static final String LCAT = "TiBareWorkletProxy";
  private Worklet worklet;

  public TiBareWorkletProxy() {
    super();
  }

  public Worklet getWorklet() { return worklet; }

  @Kroll.method
  public void handleCreationDict(KrollDict options) {
    super.handleCreationDict(options);
    Worklet.Options opts = new Worklet.Options();
    if (options != null) {
      if (options.containsKey("memoryLimit")) {
        opts.memoryLimit(options.getInt("memoryLimit"));
      }
      if (options.containsKey("assets")) {
        opts.assets(options.getString("assets"));
      }
    }
    worklet = new Worklet(opts);
  }

  private ByteBuffer toBuffer(Object payload) {
    if (payload == null) return null;
    if (payload instanceof TiBlob) {
      byte[] bytes = ((TiBlob) payload).getBytes();
      ByteBuffer buf = ByteBuffer.allocateDirect(bytes.length);
      buf.put(bytes);
      buf.flip();
      return buf;
    }
    if (payload instanceof String) {
      byte[] bytes = ((String) payload).getBytes(StandardCharsets.UTF_8);
      ByteBuffer buf = ByteBuffer.allocateDirect(bytes.length);
      buf.put(bytes);
      buf.flip();
      return buf;
    }
    return null;
  }

  @Kroll.method
  public void start(String filename, Object source, String[] arguments) throws IOException {
    if (source == null && filename.endsWith(".bundle")) {
      String name = filename.substring(0, filename.length() - ".bundle".length());
      InputStream is = TiApplication.getAppRootOrCurrentActivity().getAssets().open(name + ".bundle");
      worklet.start(filename, is, arguments);
      return;
    }
    ByteBuffer buf = toBuffer(source);
    if (buf != null) {
      worklet.start(filename, buf, arguments);
    } else {
      worklet.start(filename, arguments);
    }
  }

  @Kroll.method
  public void suspend() { worklet.suspend(); }

  @Kroll.method
  public void suspend(int linger) { worklet.suspend(linger); }

  @Kroll.method
  public void resume() { worklet.resume(); }

  @Kroll.method
  public void terminate() {
    if (worklet != null) { worklet.terminate(); worklet = null; }
  }

  @Kroll.method
  public void push(Object payload, KrollFunction callback) {
    ByteBuffer buf = toBuffer(payload);
    if (buf == null || callback == null) return;
    worklet.push(buf, (reply, error) -> {
      KrollDict result = new KrollDict();
      if (error != null) {
        result.put("error", error.getMessage());
      } else if (reply != null) {
        byte[] bytes = new byte[reply.remaining()];
        reply.get(bytes);
        result.put("reply", TiBlob.blobFromData(bytes));
      }
      // Worklet.push dispatches its callback on the Looper that was current
      // when push() was called (Handler.createAsync(Looper.myLooper())). The
      // JS thread in Titanium's V8 runtime is not guaranteed to be the main
      // thread, so explicitly post the native->JS callback to the main looper
      // to satisfy the global main-thread callback constraint (matching the
      // iOS side's [NSOperationQueue mainQueue] dispatch).
      new Handler(Looper.getMainLooper()).post(() -> {
        callback.call(getKrollObject(), new Object[] { result });
      });
    });
  }
}