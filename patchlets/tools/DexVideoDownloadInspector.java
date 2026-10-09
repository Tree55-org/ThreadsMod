import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** Exact video graph comparison and ownership across every DEX ZIP entry. */
public final class DexVideoDownloadInspector {
    private static final String CONTRACT = "video-canonical-instruction-graph-v1";
    private static final class GateFailure extends Exception {
        final String code;
        GateFailure(String code) { super(code); this.code = code; }
    }
    private static void proveHostHook(String apkPath, Map<String, ClassDef> canonical) throws Exception {
        String render = "Lthreadsmod/video/VideoMenuAdapter;";
        int calls = 0;
        int hosts = 0;
        ClassDef expectedHost = canonical.get("LX/0Lbf;");
        if (expectedHost == null) throw new GateFailure("video_canonical_native_host_missing");
        String expectedGraph = DexUpdateFlowInspector.canonicalClass(expectedHost);
        try (ZipFile archive = new ZipFile(apkPath)) {
            for (ZipEntry entry : Collections.list(archive.entries())) {
                if (entry.isDirectory() || !entry.getName().endsWith(".dex")) continue;
                Map<String, ClassDef> classes = DexUpdateFlowInspector.readPrimaryDex(apkPath, entry.getName());
                for (ClassDef owner : classes.values()) {
                    if (!"classes.dex".equals(entry.getName())
                            && owner.getType().startsWith("Lthreadsmod/video/")) {
                        throw new GateFailure("video_secondary_class_forbidden");
                    }
                    if ("LX/0Lbf;".equals(owner.getType())) {
                        hosts++;
                        if (!expectedGraph.equals(DexUpdateFlowInspector.canonicalClass(owner))) {
                            throw new GateFailure("video_native_host_instruction_graph_mismatch");
                        }
                    }
                    for (Method method : DexUpdateFlowInspector.methods(owner)) {
                        if (method.getImplementation() == null) continue;
                        for (Object instructionObject : method.getImplementation().getInstructions()) {
                            Instruction instruction = (Instruction) instructionObject;
                            if (!(instruction instanceof ReferenceInstruction)) continue;
                            Object ref = ((ReferenceInstruction) instruction).getReference();
                            if (!(ref instanceof MethodReference)) continue;
                            MethodReference call = (MethodReference) ref;
                            if (!render.equals(call.getDefiningClass()) || !"render".equals(call.getName())) continue;
                            calls++;
                            if (!"LX/0Lbf;".equals(owner.getType()) || !"invoke".equals(method.getName())
                                    || !"V".equals(call.getReturnType())
                                    || !call.getParameterTypes().toString().equals(
                                    "[LX/09dm;, Landroid/app/Activity;, Lcom/instagram/feed/media/Media;]")) {
                                throw new GateFailure("video_native_hook_caller_drift");
                            }
                        }
                    }
                }
            }
        }
        if (calls != 1 || hosts != 1) throw new GateFailure("video_native_hook_count_drift");
    }
    private static List<String> owned(Map<String, ClassDef> classes) {
        List<String> result = new ArrayList<>();
        for (String descriptor : classes.keySet()) {
            if (descriptor.startsWith("Lthreadsmod/video/")) result.add(descriptor);
        }
        Collections.sort(result);
        return result;
    }
    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte value : bytes) out.append(String.format("%02x", value & 255));
        return out.toString();
    }
    private static void inspect(String[] args) throws Exception {
        if (args.length != 2 && (args.length != 3 || !"require-host".equals(args[2]))) {
            throw new GateFailure("video_argument_contract");
        }
        Map<String, ClassDef> candidate = DexUpdateFlowInspector.readPrimaryDex(args[0], "classes.dex");
        Map<String, ClassDef> canonical = DexUpdateFlowInspector.readPrimaryDex(args[1], "classes.dex");
        if (args.length == 3) proveHostHook(args[0], canonical);
        List<String> names = owned(canonical);
        if (names.isEmpty() || !names.equals(owned(candidate))) {
            throw new GateFailure("video_class_inventory_mismatch");
        }
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        int methods = 0;
        for (String name : names) {
            String expected = DexUpdateFlowInspector.canonicalClass(canonical.get(name));
            String actual = DexUpdateFlowInspector.canonicalClass(candidate.get(name));
            if (!expected.equals(actual)) throw new GateFailure("video_instruction_graph_mismatch");
            digest.update(actual.getBytes(StandardCharsets.UTF_8));
            for (Method method : DexUpdateFlowInspector.methods(candidate.get(name))) {
                if (method.getImplementation() == null) continue;
                methods++;
                if (name.endsWith("VideoMenuAdapter;")) continue;
                for (Object instructionObject : method.getImplementation().getInstructions()) {
                    Instruction instruction = (Instruction) instructionObject;
                    if (!(instruction instanceof ReferenceInstruction)) continue;
                    Object ref = ((ReferenceInstruction) instruction).getReference();
                    if (!(ref instanceof MethodReference)) continue;
                    MethodReference call = (MethodReference) ref;
                    String owner = call.getDefiningClass();
                    if (owner.startsWith("LX/") || owner.startsWith("Lcom/instagram/")
                            || owner.startsWith("Lthreadsmod/reporting/")
                            || owner.startsWith("Lthreadsmod/autoblock/")) {
                        throw new GateFailure("video_stable_private_or_account_action_call");
                    }
                }
            }
        }
        System.out.println("{\"schemaVersion\":1,\"status\":\"passed\",\"contract\":\"" + CONTRACT + "\","
                + "\"classCount\":" + names.size() + ",\"methodCount\":" + methods
                + ",\"semanticSha256\":\"" + hex(digest.digest())
                + "\",\"instructionOperandsBranchesAndHandlersBound\":true,\"completeNativeHostInstructionGraphBound\":"
                + (args.length == 3) + ",\"allDexEntryOwnershipBound\":" + (args.length == 3) + "}");
    }
    public static void main(String[] args) {
        try {
            inspect(args);
        } catch (Throwable failure) {
            String code = failure instanceof GateFailure
                    ? ((GateFailure) failure).code : "video_inspector_internal";
            System.out.println("{\"schemaVersion\":1,\"status\":\"failed\",\"contract\":\""
                    + CONTRACT + "\",\"code\":\"" + code + "\"}");
            System.exit(1);
        }
    }
}
