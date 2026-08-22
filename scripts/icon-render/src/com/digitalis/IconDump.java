// Copyright (C) 2026 utzcoz
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
package com.digitalis;

import android.content.res.AssetManager;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.DisplayMetrics;

import java.io.FileOutputStream;
import java.lang.reflect.Method;

// Usage: com.digitalis.IconDump <iconResId> <outPath> <size> <apk1> [apk2 ...]
// Builds Resources from all given APK splits (base + config splits) so an icon
// or adaptive layer that lives in a density/config split still resolves.
public class IconDump {
    public static void main(String[] args) throws Exception {
        try {
            Class<?> vmr = Class.forName("dalvik.system.VMRuntime");
            Object rt = vmr.getMethod("getRuntime").invoke(null);
            vmr.getMethod("setHiddenApiExemptions", String[].class)
               .invoke(rt, (Object) new String[]{"L"});
        } catch (Throwable ignore) {}

        int iconResId = (int) Long.parseLong(args[0].replace("0x", ""), 16);
        String out = args[1];
        int size = Integer.parseInt(args[2]);

        AssetManager am = AssetManager.class.newInstance();
        Method addAssetPath = AssetManager.class.getMethod("addAssetPath", String.class);
        for (int i = 3; i < args.length; i++) {
            addAssetPath.invoke(am, args[i]);
        }

        DisplayMetrics dm = new DisplayMetrics();
        dm.setToDefaults();
        dm.densityDpi = 640;
        dm.density = 4.0f;
        Resources res = new Resources(am, dm, null);

        Drawable d = res.getDrawable(iconResId, null);

        Bitmap bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        d.setBounds(0, 0, size, size);
        d.draw(c);

        FileOutputStream fos = new FileOutputStream(out);
        bmp.compress(Bitmap.CompressFormat.PNG, 100, fos);
        fos.flush();
        fos.close();
        System.out.println("OK " + out);
    }
}
