import java.util.*;
import pt.unl.fct.di.novasys.babel.*;
public class DeliverNotification extends ProtoNotification
{
  public final short NOTIFICATION_ID = 202;
  private final UUID mid;
  private final Unknown37 s;
  private final Unknown38 m;
  public DeliverNotification (UUID mid, Unknown37 s, Unknown38 m)
  {
    super(NOTIFICATION_ID);
    this.mid = mid;
    this.s = s;
    this.m = m;
  }
  public UUID getMid ()
  {
    return mid;
  }
  public Unknown37 getS ()
  {
    return s;
  }
  public Unknown38 getM ()
  {
    return m;
  }
}