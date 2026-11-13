package android.annotation;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

@Target({ElementType.TYPE, ElementType.FIELD, ElementType.METHOD, ElementType.CONSTRUCTOR})
@Retention(RetentionPolicy.SOURCE)
public @interface SystemApi {
    enum Client {
        PRIVILEGED_APPS,
        MODULE_LIBRARIES,
        SYSTEM_SERVER
    }

    Client client() default Client.PRIVILEGED_APPS;
}
