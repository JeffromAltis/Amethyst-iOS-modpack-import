package net.kdt.pojavlaunch;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.*;
import java.lang.reflect.Method;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.jar.JarFile;
import java.util.jar.Manifest;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Finishes a Forge/NeoForge installation started by the launcher (Natives/installer/modpack/ModLoaderInstaller.m)
 * by running the installer's processors: the Java programs that build the patched game jar, normally run
 * by the installer's own window. They run here, in the game's JVM, right before Minecraft starts — the same
 * idea as ForgeWrapper, which Prism Launcher uses — because iOS apps can only start one JVM per launch.
 *
 * Mirrors the official installer's PostProcessors for install profile spec 0/1.
 */
public final class ModLoaderPostInstall {
    /** Written by ModLoaderInstaller.m next to the version json; keep in sync. */
    private static final String MARKER = "amethyst-postinstall.json";
    private static final String TAG = "[ModLoaderInstall] ";

    private ModLoaderPostInstall() {}

    /** Runs the pending processors of `versionId`, if any. Throws if the installation can't be completed. */
    public static void runIfPending(String versionId) throws Exception {
        File marker = new File(Tools.DIR_HOME_VERSION, versionId + "/" + MARKER);
        if (!marker.isFile()) {
            return;
        }
        JsonObject info = parse(Tools.read(marker.getAbsolutePath())).getAsJsonObject();
        File librariesDir = new File(Tools.DIR_HOME_LIBRARY);
        File installer = new File(librariesDir, info.get("installer").getAsString());
        String minecraftVersion = info.has("minecraft") ? info.get("minecraft").getAsString() : "";

        System.out.println(TAG + "Finishing the installation of " + versionId + ", this can take a few minutes");
        long start = System.currentTimeMillis();
        File temp = createTempDirectory();
        try (ZipFile installerZip = new ZipFile(installer)) {
            JsonObject profile = parse(readEntry(installerZip, "install_profile.json")).getAsJsonObject();
            fetchLibraries(profile, installerZip, librariesDir);

            Map<String, String> data = buildData(profile, installerZip, temp, librariesDir, installer, versionId, minecraftVersion);
            JsonArray processors = profile.has("processors") ? profile.getAsJsonArray("processors") : new JsonArray();
            int index = 0;
            for (JsonElement element : processors) {
                index++;
                runProcessor(element.getAsJsonObject(), data, librariesDir, index, processors.size());
            }
        } finally {
            deleteRecursively(temp);
        }
        if (!marker.delete()) {
            System.err.println(TAG + "Could not delete " + marker);
        }
        System.out.println(TAG + "Done in " + (System.currentTimeMillis() - start) / 1000 + " s");
    }

    // ------------------------------------------------------------------------------------------
    // Libraries

    /** Libraries the processors need. The launcher usually downloaded them already during the import. */
    private static void fetchLibraries(JsonObject profile, ZipFile installerZip, File librariesDir) throws IOException {
        if (!profile.has("libraries")) {
            return;
        }
        for (JsonElement element : profile.getAsJsonArray("libraries")) {
            JsonObject library = element.getAsJsonObject();
            JsonObject artifact = library.has("downloads") ? library.getAsJsonObject("downloads").getAsJsonObject("artifact") : null;
            String path = artifact != null && artifact.has("path") ? artifact.get("path").getAsString()
                : Tools.mavenPath(library.get("name").getAsString());
            if (path == null) {
                throw new IOException("Invalid library name " + library.get("name"));
            }
            String sha1 = artifact != null && artifact.has("sha1") ? artifact.get("sha1").getAsString() : null;
            String url = artifact != null && artifact.has("url") ? artifact.get("url").getAsString() : "";
            File file = safeChild(librariesDir, path);
            if (isValid(file, sha1)) {
                continue;
            }
            ZipEntry bundled = installerZip.getEntry("maven/" + path);
            if (bundled != null) {
                extract(installerZip, bundled, file);
            } else if (!url.isEmpty()) {
                System.out.println(TAG + "Downloading " + url);
                download(url, file);
            } else {
                throw new IOException("Library " + path + " is missing and has no download URL");
            }
            if (!isValid(file, sha1)) {
                throw new IOException("Library " + path + " failed its checksum");
            }
        }
    }

    // ------------------------------------------------------------------------------------------
    // Data and token substitution

    private static Map<String, String> buildData(JsonObject profile, ZipFile installerZip, File temp, File librariesDir,
                                                 File installer, String versionId, String minecraftVersion) throws IOException {
        Map<String, String> data = new HashMap<>();
        if (profile.has("data")) {
            for (Map.Entry<String, JsonElement> entry : profile.getAsJsonObject("data").entrySet()) {
                JsonObject sides = entry.getValue().getAsJsonObject();
                if (!sides.has("client")) {
                    continue;
                }
                String value = sides.get("client").getAsString();
                if (value.length() >= 2 && value.startsWith("[") && value.endsWith("]")) {
                    value = artifactFile(librariesDir, value.substring(1, value.length() - 1)).getAbsolutePath();
                } else if (value.length() >= 2 && value.startsWith("'") && value.endsWith("'")) {
                    value = value.substring(1, value.length() - 1);
                } else {
                    // A file inside the installer, e.g. "/data/client.lzma"
                    String name = value.startsWith("/") ? value.substring(1) : value;
                    ZipEntry zipEntry = installerZip.getEntry(name);
                    if (zipEntry == null) {
                        throw new IOException("The installer has no " + name);
                    }
                    File target = safeChild(temp, name);
                    extract(installerZip, zipEntry, target);
                    value = target.getAbsolutePath();
                }
                data.put(entry.getKey(), value);
            }
        }

        String mcVersion = minecraftVersion.isEmpty() && profile.has("minecraft") ? profile.get("minecraft").getAsString() : minecraftVersion;
        data.put("SIDE", "client");
        data.put("MINECRAFT_JAR", minecraftJar(versionId, mcVersion).getAbsolutePath());
        data.put("MINECRAFT_VERSION", mcVersion);
        data.put("ROOT", Tools.DIR_GAME_NEW);
        data.put("INSTALLER", installer.getAbsolutePath());
        data.put("LIBRARY_DIR", librariesDir.getAbsolutePath());
        return data;
    }

    /** The vanilla client jar. The launcher stores it under the loader's own version id (see tweakVersionJson). */
    private static File minecraftJar(String versionId, String mcVersion) throws IOException {
        File[] candidates = {
            new File(Tools.DIR_HOME_VERSION, mcVersion + "/" + mcVersion + ".jar"),
            new File(Tools.DIR_HOME_VERSION, versionId + "/" + versionId + ".jar")
        };
        for (File candidate : candidates) {
            if (candidate.isFile() && candidate.length() > 0) {
                return candidate;
            }
        }
        throw new IOException("The Minecraft " + mcVersion + " client jar is missing");
    }

    /** Same rules as the installer's Util.replaceTokens: {KEY} is substituted, 'text' is literal, \ escapes. */
    static String replaceTokens(Map<String, String> tokens, String value) {
        StringBuilder buf = new StringBuilder();
        for (int x = 0; x < value.length(); x++) {
            char c = value.charAt(x);
            if (c == '\\') {
                if (x == value.length() - 1) {
                    throw new IllegalArgumentException("Illegal pattern (Bad escape): " + value);
                }
                buf.append(value.charAt(++x));
            } else if (c == '{' || c == '\'') {
                StringBuilder key = new StringBuilder();
                for (int y = x + 1; y <= value.length(); y++) {
                    if (y == value.length()) {
                        throw new IllegalArgumentException("Illegal pattern (Unclosed " + c + "): " + value);
                    }
                    char d = value.charAt(y);
                    if (d == '\\') {
                        if (y == value.length() - 1) {
                            throw new IllegalArgumentException("Illegal pattern (Bad escape): " + value);
                        }
                        key.append(value.charAt(++y));
                    } else if ((c == '{' && d == '}') || (c == '\'' && d == '\'')) {
                        x = y;
                        break;
                    } else {
                        key.append(d);
                    }
                }
                if (c == '\'') {
                    buf.append(key);
                } else {
                    String token = tokens.get(key.toString());
                    if (token == null) {
                        throw new IllegalArgumentException("Missing key " + key + " in " + value);
                    }
                    buf.append(token);
                }
            } else {
                buf.append(c);
            }
        }
        return buf.toString();
    }

    /** A processor argument or output: [maven:coordinate] is a library path, anything else gets tokens replaced. */
    static String resolve(String value, Map<String, String> data, File librariesDir) throws IOException {
        if (value.length() >= 2 && value.startsWith("[") && value.endsWith("]")) {
            return artifactFile(librariesDir, value.substring(1, value.length() - 1)).getAbsolutePath();
        }
        return replaceTokens(data, value);
    }

    // ------------------------------------------------------------------------------------------
    // Processors

    private static void runProcessor(JsonObject processor, Map<String, String> data, File librariesDir,
                                     int index, int count) throws Exception {
        if (processor.has("sides")) {
            boolean client = false;
            for (JsonElement side : processor.getAsJsonArray("sides")) {
                client |= "client".equals(side.getAsString());
            }
            if (!client) {
                return;
            }
        }

        // Outputs that are already there and correct mean this step ran before
        Map<String, String> outputs = new LinkedHashMap<>();
        if (processor.has("outputs")) {
            for (Map.Entry<String, JsonElement> entry : processor.getAsJsonObject("outputs").entrySet()) {
                outputs.put(resolve(entry.getKey(), data, librariesDir), resolve(entry.getValue().getAsString(), data, librariesDir));
            }
        }
        if (!outputs.isEmpty()) {
            boolean upToDate = true;
            for (Map.Entry<String, String> output : outputs.entrySet()) {
                File file = new File(output.getKey());
                if (!isValid(file, output.getValue())) {
                    upToDate = false;
                    if (file.exists() && !file.delete()) {
                        throw new IOException("Could not replace " + file);
                    }
                }
            }
            if (upToDate) {
                System.out.println(TAG + "Step " + index + "/" + count + " already done");
                return;
            }
        }

        File jar = artifactFile(librariesDir, processor.get("jar").getAsString());
        List<URL> classpath = new ArrayList<>();
        classpath.add(requireFile(jar).toURI().toURL());
        if (processor.has("classpath")) {
            for (JsonElement entry : processor.getAsJsonArray("classpath")) {
                classpath.add(requireFile(artifactFile(librariesDir, entry.getAsString())).toURI().toURL());
            }
        }
        String mainClass;
        try (JarFile jarFile = new JarFile(jar)) {
            Manifest manifest = jarFile.getManifest();
            mainClass = manifest == null ? null : manifest.getMainAttributes().getValue("Main-Class");
        }
        if (mainClass == null || mainClass.isEmpty()) {
            throw new IOException(jar.getName() + " has no Main-Class");
        }

        List<String> args = new ArrayList<>();
        if (processor.has("args")) {
            for (JsonElement arg : processor.getAsJsonArray("args")) {
                args.add(resolve(arg.getAsString(), data, librariesDir));
            }
        }

        System.out.println(TAG + "Step " + index + "/" + count + ": " + processor.get("jar").getAsString());
        Thread thread = Thread.currentThread();
        ClassLoader previous = thread.getContextClassLoader();
        // Isolated from the launcher's own classes, like the installer does
        try (URLClassLoader loader = new URLClassLoader(classpath.toArray(new URL[0]), platformClassLoader())) {
            thread.setContextClassLoader(loader);
            Method main = Class.forName(mainClass, true, loader).getMethod("main", String[].class);
            main.invoke(null, (Object) args.toArray(new String[0]));
        } catch (java.lang.reflect.InvocationTargetException e) {
            throw new IOException("Step " + index + " (" + mainClass + ") failed", e.getCause());
        } finally {
            thread.setContextClassLoader(previous);
        }

        for (Map.Entry<String, String> output : outputs.entrySet()) {
            if (!isValid(new File(output.getKey()), output.getValue())) {
                throw new IOException("Step " + index + " did not produce a valid " + output.getKey());
            }
        }
    }

    private static ClassLoader platformClassLoader() {
        try {
            // Java 9+; null (the bootstrap loader) is the equivalent on Java 8
            return (ClassLoader) ClassLoader.class.getMethod("getPlatformClassLoader").invoke(null);
        } catch (ReflectiveOperationException e) {
            return null;
        }
    }

    // ------------------------------------------------------------------------------------------
    // Files

    static File artifactFile(File librariesDir, String coordinate) throws IOException {
        String path = Tools.mavenPath(coordinate);
        if (path == null) {
            throw new IOException("Invalid artifact " + coordinate);
        }
        return safeChild(librariesDir, path);
    }

    private static File requireFile(File file) throws IOException {
        if (!file.isFile()) {
            throw new IOException("Missing " + file);
        }
        return file;
    }

    /** `name` under `base`, refusing paths that would leave it. */
    static File safeChild(File base, String name) throws IOException {
        File file = new File(base, name);
        String basePath = base.getCanonicalPath() + File.separator;
        if (!file.getCanonicalPath().startsWith(basePath)) {
            throw new IOException("Refusing path outside " + base + ": " + name);
        }
        return file;
    }

    /** A file is valid if it exists and, when a checksum is known, matches it. */
    static boolean isValid(File file, String sha1) throws IOException {
        if (!file.isFile()) {
            return false;
        }
        return sha1 == null || sha1.isEmpty() || sha1.equalsIgnoreCase(sha1(file));
    }

    static String sha1(File file) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-1");
            byte[] buffer = new byte[65536];
            int read;
            while ((read = in.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
            }
            StringBuilder hex = new StringBuilder();
            for (byte b : digest.digest()) {
                hex.append(String.format("%02x", b));
            }
            return hex.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
    }

    private static void extract(ZipFile zip, ZipEntry entry, File target) throws IOException {
        File parent = target.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
            throw new IOException("Could not create " + parent);
        }
        File part = new File(target.getPath() + ".part");
        try (InputStream in = zip.getInputStream(entry); OutputStream out = new FileOutputStream(part)) {
            Tools.copy(in, out);
        }
        replace(part, target);
    }

    private static void download(String url, File target) throws IOException {
        File parent = target.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
            throw new IOException("Could not create " + parent);
        }
        File part = new File(target.getPath() + ".part");
        HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
        connection.setConnectTimeout(30000);
        connection.setReadTimeout(60000);
        try {
            if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) {
                throw new IOException("HTTP " + connection.getResponseCode() + " for " + url);
            }
            try (InputStream in = connection.getInputStream(); OutputStream out = new FileOutputStream(part)) {
                Tools.copy(in, out);
            }
        } finally {
            connection.disconnect();
        }
        replace(part, target);
    }

    private static void replace(File source, File target) throws IOException {
        if (target.exists() && !target.delete()) {
            throw new IOException("Could not replace " + target);
        }
        if (!source.renameTo(target)) {
            throw new IOException("Could not move " + source + " to " + target);
        }
    }

    private static File createTempDirectory() throws IOException {
        File temp = File.createTempFile("loader-install", "");
        if (!temp.delete() || !temp.mkdirs()) {
            throw new IOException("Could not create a temporary directory");
        }
        return temp;
    }

    private static void deleteRecursively(File file) {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        file.delete();
    }

    private static String readEntry(ZipFile zip, String name) throws IOException {
        ZipEntry entry = zip.getEntry(name);
        if (entry == null) {
            throw new IOException("The installer has no " + name);
        }
        try (InputStream in = zip.getInputStream(entry)) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            Tools.copy(in, bytes);
            return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    @SuppressWarnings("deprecation")
    private static JsonElement parse(String json) {
        return new JsonParser().parse(json);
    }
}
