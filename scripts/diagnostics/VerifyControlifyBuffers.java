import java.lang.foreign.*;
import java.lang.reflect.*;
import java.nio.*;
import dev.isxander.sdl.*;
import net.kdt.patchjna.ControlifySDL;
public class VerifyControlifyBuffers {
 public static void main(String[] args)throws Exception {
  Class<?> session=Class.forName("net.kdt.patchjna.ControlifySDL$Session");
  Constructor<?> ctor=session.getDeclaredConstructor();ctor.setAccessible(true);Object state=ctor.newInstance();
  Method wrap=ControlifySDL.class.getDeclaredMethod("wrap",Object.class,Class.class,session);wrap.setAccessible(true);
  final Thread owner=Thread.currentThread();
  SdlGamepad delegate=(SdlGamepad)Proxy.newProxyInstance(SdlGamepad.class.getClassLoader(),new Class[]{SdlGamepad.class},(proxy,method,a)->{
   if(!method.getName().equals("SDL_GetGamepadSensorData"))throw new AssertionError("Unexpected call");
   if(Thread.currentThread()!=owner)throw new AssertionError("Buffer moved threads");
   ((FloatBuffer)a[2]).put(0,42f);return true;
  });
  SdlGamepad routed=(SdlGamepad)wrap.invoke(null,delegate,SdlGamepad.class,state);
  try(Arena arena=Arena.ofConfined()) {
   FloatBuffer buffer=arena.allocate(12).asByteBuffer().order(ByteOrder.nativeOrder()).asFloatBuffer();
   if(!routed.SDL_GetGamepadSensorData(new SdlGamepadHandle(1),1,buffer)||buffer.get(0)!=42f)throw new AssertionError("Sensor forwarding");
  }
  System.out.println("PASS: confined sensor buffer stays on owner thread and receives output without UIKit dispatch");
 }
}
