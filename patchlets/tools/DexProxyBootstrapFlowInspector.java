import com.android.tools.smali.dexlib2.base.BaseTryBlock;
import com.android.tools.smali.dexlib2.base.reference.BaseStringReference;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.ExceptionHandler;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MethodImplementation;
import com.android.tools.smali.dexlib2.iface.instruction.FiveRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.NarrowLiteralInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.OffsetInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.RegisterRangeInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.SwitchElement;
import com.android.tools.smali.dexlib2.iface.instruction.SwitchPayload;
import com.android.tools.smali.dexlib2.iface.instruction.TwoRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.VariableRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Proves the exact signed-Dex Application bootstrap prefix for patchlet 080.
 *
 * This verifier intentionally does not depend on JADX rendering the large host
 * attachBaseContext method. The exact-SHA resolution supplies the owner, super,
 * and bootstrap method references. The reviewed register prefix and the first
 * untouched Threads field access are fixed here so a moved, duplicated, caught,
 * alternate-entry, wrong-context, or Java-proxy fallback hook fails closed.
 */
public final class DexProxyBootstrapFlowInspector {
    private static final String CONTRACT = "socks5-bootstrap-signed-dex-flow-contract";
    private static final String CONTEXT = "Landroid/content/Context;";

    private static final List<String> FORBIDDEN_FALLBACK_STRINGS =
            Collections.unmodifiableList(Arrays.asList(
                    "socksProxyHost", "socksProxyPort", "java.net.useSystemProxies"));
    private static final List<String> FORBIDDEN_FALLBACK_METHODS =
            Collections.unmodifiableList(Arrays.asList(
                    "Landroid/net/VpnService$Builder;->allowBypass()Landroid/net/VpnService$Builder;",
                    "Ljava/lang/System;->setProperty(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                    "Ljava/net/ProxySelector;->setDefault(Ljava/net/ProxySelector;)V"));

    private static final class ContractFailure extends Exception {
        final String code;

        ContractFailure(String code) {
            super(code);
            this.code = code;
        }
    }

    private static final class CallSpec {
        final String owner;
        final String name;
        final String descriptor;

        CallSpec(String owner, String name, String descriptor) {
            this.owner = owner;
            this.name = name;
            this.descriptor = descriptor;
        }
    }

    private static final class AnchorLayout {
        final String expectedDex;
        final int contextMoveIndex;
        final int contextMoveDestination;
        final int thisMoveIndex;
        final int thisMoveDestination;
        final int superIndex;
        final int fieldRegister;
        final String fieldOwner;
        final String fieldName;
        final String fieldType;
        final CallSpec entryValidationCall;

        AnchorLayout(
                String expectedDex,
                int contextMoveIndex,
                int contextMoveDestination,
                int thisMoveIndex,
                int thisMoveDestination,
                int superIndex,
                int fieldRegister,
                String fieldOwner,
                String fieldName,
                String fieldType,
                CallSpec entryValidationCall) {
            this.expectedDex = expectedDex;
            this.contextMoveIndex = contextMoveIndex;
            this.contextMoveDestination = contextMoveDestination;
            this.thisMoveIndex = thisMoveIndex;
            this.thisMoveDestination = thisMoveDestination;
            this.superIndex = superIndex;
            this.fieldRegister = fieldRegister;
            this.fieldOwner = fieldOwner;
            this.fieldName = fieldName;
            this.fieldType = fieldType;
            this.entryValidationCall = entryValidationCall;
        }

        String fieldReference() {
            return fieldOwner + "->" + fieldName + ":" + fieldType;
        }
    }

    private static AnchorLayout reviewedLayout(String expectedDex) throws ContractFailure {
        if ("classes10.dex".equals(expectedDex)) {
            return new AnchorLayout(
                    expectedDex, 1, 0, 0, 4, 2, 3,
                    "LX/319;", "A05", "LX/319;", null);
        }
        if ("classes6.dex".equals(expectedDex)) {
            return new AnchorLayout(
                    expectedDex, 1, 1, 3, 0, 4, 1,
                    "LX/0143;", "A06", "LX/0143;",
                    new CallSpec("LX/0330;", "A0m", "(Ljava/lang/Object;I)V"));
        }
        throw new ContractFailure("unsupported_reviewed_layout");
    }

    private static final class CodeInstruction {
        final Instruction instruction;
        final int offset;

        CodeInstruction(Instruction instruction, int offset) {
            this.instruction = instruction;
            this.offset = offset;
        }
    }

    private static final class MethodView {
        final Method method;
        final MethodImplementation implementation;
        final List<CodeInstruction> code = new ArrayList<>();
        final int thisRegister;
        final int contextRegister;

        MethodView(Method method) throws ContractFailure {
            this.method = method;
            this.implementation = method.getImplementation();
            require(implementation != null, "owner_method_implementation_missing");
            require((method.getAccessFlags() & 0x8) == 0, "owner_method_static");
            require(method.getParameterTypes().size() == 1
                            && CONTEXT.equals(String.valueOf(method.getParameterTypes().get(0))),
                    "owner_method_parameter_shape");
            int parameterWords = 1;
            this.thisRegister = implementation.getRegisterCount() - parameterWords - 1;
            this.contextRegister = thisRegister + 1;
            require(thisRegister >= 0
                            && contextRegister < implementation.getRegisterCount(),
                    "owner_method_parameter_registers");
            int offset = 0;
            for (Object object : implementation.getInstructions()) {
                Instruction instruction = (Instruction) object;
                code.add(new CodeInstruction(instruction, offset));
                offset += instruction.getCodeUnits();
            }
            require(code.size() >= 5, "owner_method_entry_too_short");
        }
    }

    private static void require(boolean condition, String code) throws ContractFailure {
        if (!condition) throw new ContractFailure(code);
    }

    private static byte[] readAll(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[65536];
        int count;
        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private static String methodDescriptor(MethodReference method) {
        StringBuilder value = new StringBuilder("(");
        for (Object parameter : method.getParameterTypes()) value.append(parameter);
        return value.append(')').append(method.getReturnType()).toString();
    }

    private static String methodReference(MethodReference method) {
        return method.getDefiningClass() + "->" + method.getName()
                + methodDescriptor(method);
    }

    private static Iterable<Method> methods(ClassDef classDef) {
        List<Method> result = new ArrayList<>();
        for (Object method : classDef.getDirectMethods()) result.add((Method) method);
        for (Object method : classDef.getVirtualMethods()) result.add((Method) method);
        return result;
    }

    private static boolean methodMatches(Instruction instruction, CallSpec spec) {
        if (!(instruction instanceof ReferenceInstruction)
                || !instruction.getOpcode().name().startsWith("INVOKE_")) return false;
        Reference reference = ((ReferenceInstruction) instruction).getReference();
        if (!(reference instanceof MethodReference)) return false;
        MethodReference method = (MethodReference) reference;
        return spec.owner.equals(method.getDefiningClass())
                && spec.name.equals(method.getName())
                && spec.descriptor.equals(methodDescriptor(method));
    }

    private static int[] invocationRegisters(Instruction instruction) throws ContractFailure {
        require(instruction instanceof VariableRegisterInstruction,
                "invoke_register_interface_missing");
        int count = ((VariableRegisterInstruction) instruction).getRegisterCount();
        if (instruction instanceof RegisterRangeInstruction) {
            int start = ((RegisterRangeInstruction) instruction).getStartRegister();
            int[] registers = new int[count];
            for (int index = 0; index < count; index++) registers[index] = start + index;
            return registers;
        }
        require(instruction instanceof FiveRegisterInstruction,
                "invoke_register_format_unsupported");
        FiveRegisterInstruction five = (FiveRegisterInstruction) instruction;
        int[] available = {
                five.getRegisterC(), five.getRegisterD(), five.getRegisterE(),
                five.getRegisterF(), five.getRegisterG()
        };
        require(count >= 0 && count <= available.length, "invoke_register_count_invalid");
        return Arrays.copyOf(available, count);
    }

    private static int oneCall(MethodView view, CallSpec spec, String code)
            throws ContractFailure {
        int found = -1;
        int count = 0;
        for (int index = 0; index < view.code.size(); index++) {
            if (!methodMatches(view.code.get(index).instruction, spec)) continue;
            found = index;
            count++;
        }
        require(count == 1, code);
        return found;
    }

    private static boolean isMoveFrom(
            Instruction instruction, String opcode, int destination, int source) {
        return opcode.equals(instruction.getOpcode().name())
                && instruction instanceof TwoRegisterInstruction
                && ((TwoRegisterInstruction) instruction).getRegisterA() == destination
                && ((TwoRegisterInstruction) instruction).getRegisterB() == source;
    }

    private static boolean fieldMatches(AnchorLayout layout, Instruction instruction) {
        if (!"SGET_OBJECT".equals(instruction.getOpcode().name())
                || !(instruction instanceof OneRegisterInstruction)
                || !(instruction instanceof ReferenceInstruction)
                || ((OneRegisterInstruction) instruction).getRegisterA()
                != layout.fieldRegister) return false;
        Reference reference = ((ReferenceInstruction) instruction).getReference();
        if (!(reference instanceof FieldReference)) return false;
        FieldReference field = (FieldReference) reference;
        return layout.fieldOwner.equals(field.getDefiningClass())
                && layout.fieldName.equals(field.getName())
                && layout.fieldType.equals(field.getType());
    }

    private static boolean isZeroConst(Instruction instruction, int register) {
        return "CONST_4".equals(instruction.getOpcode().name())
                && instruction instanceof OneRegisterInstruction
                && instruction instanceof NarrowLiteralInstruction
                && ((OneRegisterInstruction) instruction).getRegisterA() == register
                && ((NarrowLiteralInstruction) instruction).getNarrowLiteral() == 0;
    }

    private static boolean targetIs(
            int sourceOffset, OffsetInstruction instruction, int first, int second) {
        int target = sourceOffset + instruction.getCodeOffset();
        return target == first || target == second;
    }

    private static int alternateEntryCount(
            MethodView view, int superOffset, int bootstrapOffset) throws ContractFailure {
        int alternateEntries = 0;
        for (CodeInstruction item : view.code) {
            Instruction instruction = item.instruction;
            if (instruction instanceof OffsetInstruction
                    && targetIs(item.offset, (OffsetInstruction) instruction,
                    superOffset, bootstrapOffset)) {
                alternateEntries++;
            }
            String opcode = instruction.getOpcode().name();
            if ((opcode.equals("PACKED_SWITCH") || opcode.equals("SPARSE_SWITCH"))
                    && instruction instanceof OffsetInstruction) {
                int payloadOffset = item.offset
                        + ((OffsetInstruction) instruction).getCodeOffset();
                SwitchPayload payload = null;
                for (CodeInstruction candidate : view.code) {
                    if (candidate.offset == payloadOffset
                            && candidate.instruction instanceof SwitchPayload) {
                        payload = (SwitchPayload) candidate.instruction;
                        break;
                    }
                }
                require(payload != null, "switch_payload_missing");
                for (Object object : payload.getSwitchElements()) {
                    int target = item.offset + ((SwitchElement) object).getOffset();
                    if (target == superOffset || target == bootstrapOffset) alternateEntries++;
                }
            }
        }
        for (Object tryObject : view.implementation.getTryBlocks()) {
            BaseTryBlock tryBlock = (BaseTryBlock) tryObject;
            for (Object handlerObject : tryBlock.getExceptionHandlers()) {
                int handlerOffset = ((ExceptionHandler) handlerObject).getHandlerCodeAddress();
                if (handlerOffset == superOffset || handlerOffset == bootstrapOffset) {
                    alternateEntries++;
                }
            }
        }
        return alternateEntries;
    }

    private static boolean isCoveredByTry(MethodView view, int offset) {
        for (Object tryObject : view.implementation.getTryBlocks()) {
            BaseTryBlock tryBlock = (BaseTryBlock) tryObject;
            int start = tryBlock.getStartCodeAddress();
            int end = start + tryBlock.getCodeUnitCount();
            if (offset >= start && offset < end) return true;
        }
        return false;
    }

    private static boolean forbiddenFallbackReference(Instruction instruction) {
        if (!(instruction instanceof ReferenceInstruction)) return false;
        Reference reference = ((ReferenceInstruction) instruction).getReference();
        if (reference instanceof BaseStringReference
                && FORBIDDEN_FALLBACK_STRINGS.contains(
                        ((BaseStringReference) reference).getString())) return true;
        if (!(reference instanceof MethodReference)) return false;
        return FORBIDDEN_FALLBACK_METHODS.contains(
                methodReference((MethodReference) reference));
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r");
    }

    private static void emitFailure(String code) {
        System.out.println("{\"schemaVersion\":1,\"status\":\"failed\",\"contract\":\""
                + CONTRACT + "\",\"code\":\"" + escape(code) + "\"}");
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 11) {
            System.err.println("usage: APK EXPECTED_DEX OWNER_CLASS OWNER_METHOD OWNER_DESC "
                    + "SUPER_CLASS SUPER_METHOD SUPER_DESC BOOTSTRAP_CLASS "
                    + "BOOTSTRAP_METHOD BOOTSTRAP_DESC");
            System.exit(2);
        }
        try {
            String apkPath = args[0];
            String expectedDex = args[1];
            CallSpec owner = new CallSpec(args[2], args[3], args[4]);
            CallSpec superCall = new CallSpec(args[5], args[6], args[7]);
            CallSpec bootstrap = new CallSpec(args[8], args[9], args[10]);
            require(expectedDex.matches("classes(?:[2-9]|[1-9][0-9]+)?\\.dex"),
                    "expected_dex_name_invalid");
            require(owner.owner.startsWith("L") && owner.owner.endsWith(";")
                            && "attachBaseContext".equals(owner.name)
                            && ("(" + CONTEXT + ")V").equals(owner.descriptor),
                    "owner_reference_invalid");
            require(superCall.owner.startsWith("L") && superCall.owner.endsWith(";")
                            && "attachBaseContext".equals(superCall.name)
                            && owner.descriptor.equals(superCall.descriptor),
                    "super_reference_invalid");
            require(bootstrap.owner.startsWith("L") && bootstrap.owner.endsWith(";")
                            && "install".equals(bootstrap.name)
                            && owner.descriptor.equals(bootstrap.descriptor),
                    "bootstrap_reference_invalid");
            AnchorLayout layout = reviewedLayout(expectedDex);

            int expectedDexCount = 0;
            int ownerClassCount = 0;
            int ownerMethodCount = 0;
            int globalBootstrapCalls = 0;
            MethodView ownerMethod = null;
            Set<String> archiveNames = new HashSet<>();
            try (ZipFile apk = new ZipFile(apkPath)) {
                List<? extends ZipEntry> entries = Collections.list(apk.entries());
                entries.sort((left, right) -> left.getName().compareTo(right.getName()));
                for (ZipEntry entry : entries) {
                    require(archiveNames.add(entry.getName()), "duplicate_archive_entry");
                    if (entry.isDirectory() || !entry.getName().endsWith(".dex")) continue;
                    if (expectedDex.equals(entry.getName())) expectedDexCount++;
                    byte[] bytes;
                    try (InputStream input = apk.getInputStream(entry)) {
                        bytes = readAll(input);
                    }
                    DexBackedDexFile dex = new DexBackedDexFile(bytes, 0);
                    for (Object classObject : dex.classSection) {
                        ClassDef classDef = (ClassDef) classObject;
                        boolean isOwner = owner.owner.equals(classDef.getType());
                        if (isOwner) {
                            ownerClassCount++;
                            require(expectedDex.equals(entry.getName()),
                                    "owner_class_wrong_dex");
                        }
                        for (Method method : methods(classDef)) {
                            MethodImplementation implementation = method.getImplementation();
                            if (implementation != null) {
                                for (Object instructionObject : implementation.getInstructions()) {
                                    if (methodMatches((Instruction) instructionObject, bootstrap)) {
                                        globalBootstrapCalls++;
                                    }
                                }
                            }
                            if (isOwner && owner.name.equals(method.getName())
                                    && owner.descriptor.equals(methodDescriptor(method))) {
                                ownerMethodCount++;
                                ownerMethod = new MethodView(method);
                            }
                        }
                    }
                }
            }
            require(expectedDexCount == 1, "expected_dex_count");
            require(ownerClassCount == 1, "owner_class_count");
            require(ownerMethodCount == 1 && ownerMethod != null, "owner_method_count");
            require(globalBootstrapCalls == 1, "bootstrap_global_call_count");

            int superIndex = oneCall(ownerMethod, superCall, "super_owner_call_count");
            int bootstrapIndex = oneCall(
                    ownerMethod, bootstrap, "bootstrap_owner_call_count");
            require(isMoveFrom(ownerMethod.code.get(layout.thisMoveIndex).instruction,
                            "MOVE_OBJECT_FROM16", layout.thisMoveDestination,
                            ownerMethod.thisRegister),
                    "entry_this_move");
            require(isMoveFrom(ownerMethod.code.get(layout.contextMoveIndex).instruction,
                            "MOVE_OBJECT_FROM16", layout.contextMoveDestination,
                            ownerMethod.contextRegister),
                    "entry_context_move");
            if (layout.entryValidationCall != null) {
                require(isZeroConst(ownerMethod.code.get(0).instruction, 2),
                        "entry_validation_zero");
                require(methodMatches(ownerMethod.code.get(2).instruction,
                                layout.entryValidationCall),
                        "entry_validation_call");
                require(Arrays.equals(
                                invocationRegisters(ownerMethod.code.get(2).instruction),
                                new int[] {layout.contextMoveDestination, 2}),
                        "entry_validation_register_flow");
            }
            require(superIndex == layout.superIndex, "super_entry_position");
            require("INVOKE_SUPER".equals(
                            ownerMethod.code.get(superIndex).instruction.getOpcode().name()),
                    "super_opcode");
            int[] superRegisters = invocationRegisters(
                    ownerMethod.code.get(superIndex).instruction);
            require(Arrays.equals(superRegisters, new int[] {
                            layout.thisMoveDestination, layout.contextMoveDestination}),
                    "super_register_flow");
            require(bootstrapIndex == superIndex + 1, "bootstrap_not_adjacent");
            require("INVOKE_STATIC".equals(
                            ownerMethod.code.get(bootstrapIndex).instruction.getOpcode().name()),
                    "bootstrap_opcode");
            int[] bootstrapRegisters = invocationRegisters(
                    ownerMethod.code.get(bootstrapIndex).instruction);
            require(Arrays.equals(bootstrapRegisters,
                            new int[] {layout.contextMoveDestination}),
                    "bootstrap_register_flow");
            require(fieldMatches(layout,
                            ownerMethod.code.get(bootstrapIndex + 1).instruction),
                    "original_anchor_not_adjacent");

            int superOffset = ownerMethod.code.get(superIndex).offset;
            int bootstrapOffset = ownerMethod.code.get(bootstrapIndex).offset;
            require(alternateEntryCount(ownerMethod, superOffset, bootstrapOffset) == 0,
                    "bootstrap_alternate_entry");
            require(!isCoveredByTry(ownerMethod, superOffset)
                            && !isCoveredByTry(ownerMethod, bootstrapOffset),
                    "bootstrap_try_coverage");
            for (CodeInstruction item : ownerMethod.code) {
                require(!forbiddenFallbackReference(item.instruction),
                        "bootstrap_fallback_reference");
            }

            System.out.println("{\"schemaVersion\":1,\"status\":\"passed\"," +
                    "\"contract\":\"" + CONTRACT + "\",\"dex\":\""
                    + escape(expectedDex) + "\",\"owner\":\"" + escape(owner.owner)
                    + "\",\"method\":\"" + escape(owner.name + owner.descriptor)
                    + "\",\"superOffset\":" + superOffset
                    + ",\"bootstrapOffset\":" + bootstrapOffset
                    + ",\"originalAnchorOffset\":"
                    + ownerMethod.code.get(bootstrapIndex + 1).offset
                    + ",\"thisRegister\":" + ownerMethod.thisRegister
                    + ",\"contextRegister\":" + ownerMethod.contextRegister
                    + ",\"bootstrapCallCount\":" + globalBootstrapCalls
                    + ",\"originalAnchorField\":\""
                    + escape(layout.fieldReference()) + "\""
                    + ",\"forbiddenFallbackStrings\":[\"socksProxyHost\","
                    + "\"socksProxyPort\",\"java.net.useSystemProxies\"]"
                    + ",\"forbiddenFallbackMethods\":["
                    + "\"Landroid/net/VpnService$Builder;->allowBypass()"
                    + "Landroid/net/VpnService$Builder;\","
                    + "\"Ljava/lang/System;->setProperty(Ljava/lang/String;"
                    + "Ljava/lang/String;)Ljava/lang/String;\","
                    + "\"Ljava/net/ProxySelector;->setDefault(Ljava/net/ProxySelector;)V\"]"
                    + ",\"checks\":{\"exactEntryPrefix\":true,"
                    + "\"soleBootstrapCaller\":true,\"sameContextRegister\":true,"
                    + "\"adjacentAfterSuper\":true,\"noAlternateEntry\":true,"
                    + "\"outsideTryRanges\":true,\"originalAnchorAdjacent\":true,"
                    + "\"fallbackReferencesAbsent\":true}}");
        } catch (ContractFailure failure) {
            emitFailure(failure.code);
            System.exit(1);
        } catch (Throwable ignored) {
            emitFailure("inspector_internal_failure");
            System.exit(1);
        }
    }
}
