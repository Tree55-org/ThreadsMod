import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.base.BaseTryBlock;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.ExceptionHandler;
import com.android.tools.smali.dexlib2.iface.Field;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MethodImplementation;
import com.android.tools.smali.dexlib2.iface.instruction.FiveRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.OffsetInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.RegisterRangeInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.TwoRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.VariableRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.WideLiteralInstruction;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;
import com.android.tools.smali.dexlib2.iface.reference.TypeReference;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Proves the reviewed report-permalink value flow in the signed primary DEX.
 *
 * This intentionally operates on DEX instructions, registers and normal
 * control-flow edges. Finding the relevant classes, calls, fields and strings
 * independently is not sufficient.
 */
public final class DexReportPermalinkFlowInspector {
    private static final String CONTRACT = "report-post-permalink-contract";
    private static final String PRIMARY_DEX = "classes.dex";
    private static final String STRING = "Ljava/lang/String;";
    private static final int OPCODE_SETS_REGISTER = 0x10;
    private static final int OPCODE_SETS_WIDE_REGISTER = 0x20;
    private static final String OTHER = "<other>";

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

        static CallSpec parse(String value, String code) throws ContractFailure {
            int arrow = value.indexOf("->");
            int open = value.indexOf('(', arrow + 2);
            require(arrow > 0 && open > arrow + 2 && value.endsWith(";")
                    || arrow > 0 && open > arrow + 2, code);
            String owner = value.substring(0, arrow);
            String name = value.substring(arrow + 2, open);
            String descriptor = value.substring(open);
            require(owner.startsWith("L") && owner.endsWith(";")
                    && !name.isEmpty() && descriptor.indexOf(')') > 0, code);
            return new CallSpec(owner, name, descriptor);
        }

        String key() {
            return owner + "->" + name + descriptor;
        }
    }

    private static final class FieldSpec {
        final String owner;
        final String name;
        final String type;

        FieldSpec(String owner, String name, String type) {
            this.owner = owner;
            this.name = name;
            this.type = type;
        }

        static FieldSpec parse(String value, String code) throws ContractFailure {
            int arrow = value.indexOf("->");
            int colon = value.indexOf(':', arrow + 2);
            require(arrow > 0 && colon > arrow + 2, code);
            String owner = value.substring(0, arrow);
            String name = value.substring(arrow + 2, colon);
            String type = value.substring(colon + 1);
            require(owner.startsWith("L") && owner.endsWith(";")
                    && !name.isEmpty() && !type.isEmpty(), code);
            return new FieldSpec(owner, name, type);
        }

        String key() {
            return owner + "->" + name + ":" + type;
        }
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
        final Map<Integer, Integer> indexByOffset = new HashMap<>();
        final int[] parameters;
        final int thisRegister;
        String[][] origins;

        MethodView(Method method) throws ContractFailure {
            this.method = method;
            implementation = method.getImplementation();
            require(implementation != null, "method_implementation_missing");
            int offset = 0;
            int index = 0;
            for (Object object : implementation.getInstructions()) {
                Instruction instruction = (Instruction) object;
                code.add(new CodeInstruction(instruction, offset));
                indexByOffset.put(offset, index++);
                offset += instruction.getCodeUnits();
            }
            require(!code.isEmpty(), "method_code_empty");
            boolean isStatic = (method.getAccessFlags() & 0x8) != 0;
            List<? extends CharSequence> types = method.getParameterTypes();
            parameters = new int[types.size()];
            int parameterWords = 0;
            for (Object type : types) parameterWords += typeWords(type);
            int next = implementation.getRegisterCount() - parameterWords;
            require(next >= 0, "method_parameter_registers_invalid");
            thisRegister = isStatic ? -1 : next - 1;
            require(isStatic || thisRegister >= 0, "method_this_register_invalid");
            for (int parameter = 0; parameter < types.size(); parameter++) {
                parameters[parameter] = next;
                next += typeWords(types.get(parameter));
            }
        }

        int indexAt(int offset, String code) throws ContractFailure {
            Integer index = indexByOffset.get(offset);
            require(index != null, code);
            return index;
        }
    }

    private static final class Evidence {
        int factoryPermalinkCallOffset;
        int factoryCodeCallOffset;
        int factoryPermalinkResolverOffset;
        int factoryPermalinkFallbackGuardOffset;
        int factoryFallbackPermalinkResolverOffset;
        int factoryCaptionTextCallOffset;
        int factoryExcerptResolverOffset;
        int factoryConstructorOffset;
        int constructorSanitizerOffset;
        int constructorStoreOffset;
        int validityBaseGuardOffset;
        int validityPermalinkGuardOffset;
        int payloadTargetUrlOffset;
        int payloadEvidenceValueOffset;
        int payloadEvidenceContainerOffset;
        int controllerValidityGuardOffset;
        int clientValidityGuardOffset;
        int rowVisibilityModifierOffset;
        int rowTestTagOffset;
        int rowModifierComposedOffset;
        int rowUfiButtonOffset;
        int rowUfiButtonDefaultMask;
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

    private static int typeWords(Object type) {
        String value = String.valueOf(type);
        return value.equals("J") || value.equals("D") ? 2 : 1;
    }

    private static String methodDescriptor(MethodReference method) {
        StringBuilder value = new StringBuilder("(");
        for (Object parameter : method.getParameterTypes()) value.append(parameter);
        return value.append(')').append(method.getReturnType()).toString();
    }

    private static Iterable<Method> methods(ClassDef classDef) {
        List<Method> result = new ArrayList<>();
        for (Object method : classDef.getDirectMethods()) result.add((Method) method);
        for (Object method : classDef.getVirtualMethods()) result.add((Method) method);
        return result;
    }

    private static Map<String, ClassDef> readPrimaryDex(String apkPath) throws Exception {
        Map<String, ClassDef> classes = new HashMap<>();
        int primaryCount = 0;
        Set<String> names = new HashSet<>();
        try (ZipFile apk = new ZipFile(apkPath)) {
            List<? extends ZipEntry> entries = Collections.list(apk.entries());
            for (ZipEntry entry : entries) {
                if (!names.add(entry.getName())) {
                    throw new ContractFailure("duplicate_archive_entry");
                }
                if (!entry.isDirectory() && PRIMARY_DEX.equals(entry.getName())) {
                    primaryCount++;
                    byte[] bytes;
                    try (InputStream input = apk.getInputStream(entry)) {
                        bytes = readAll(input);
                    }
                    DexBackedDexFile dex = new DexBackedDexFile(bytes, 0);
                    for (Object object : dex.classSection) {
                        ClassDef classDef = (ClassDef) object;
                        require(classes.put(classDef.getType(), classDef) == null,
                                "duplicate_primary_class");
                    }
                }
            }
        }
        require(primaryCount == 1, "primary_dex_count");
        return classes;
    }

    private static MethodView exactMethod(
            Map<String, ClassDef> classes, CallSpec spec, String code) throws ContractFailure {
        ClassDef classDef = classes.get(spec.owner);
        require(classDef != null, code + "_class");
        Method found = null;
        for (Method method : methods(classDef)) {
            if (!spec.name.equals(method.getName())
                    || !spec.descriptor.equals(methodDescriptor(method))) continue;
            require(found == null, code + "_duplicate");
            found = method;
        }
        require(found != null, code + "_missing");
        return new MethodView(found);
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

    private static List<Integer> callIndexes(MethodView view, CallSpec spec) {
        List<Integer> result = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            if (methodMatches(view.code.get(index).instruction, spec)) result.add(index);
        }
        return result;
    }

    private static int oneCall(MethodView view, CallSpec spec, String code)
            throws ContractFailure {
        List<Integer> calls = callIndexes(view, spec);
        require(calls.size() == 1, code);
        return calls.get(0);
    }

    private static int classCallCount(
            Map<String, ClassDef> classes, String owner, CallSpec target,
            String code) throws ContractFailure {
        ClassDef classDef = classes.get(owner);
        require(classDef != null, code + "_class");
        int count = 0;
        for (Method method : methods(classDef)) {
            if (method.getImplementation() == null) continue;
            count += callIndexes(new MethodView(method), target).size();
        }
        return count;
    }

    private static int[] invocationRegisters(Instruction instruction) throws ContractFailure {
        require(instruction instanceof VariableRegisterInstruction,
                "invoke_register_format_missing");
        int count = ((VariableRegisterInstruction) instruction).getRegisterCount();
        if (instruction instanceof RegisterRangeInstruction) {
            int start = ((RegisterRangeInstruction) instruction).getStartRegister();
            int[] result = new int[count];
            for (int index = 0; index < count; index++) result[index] = start + index;
            return result;
        }
        if (instruction instanceof FiveRegisterInstruction) {
            FiveRegisterInstruction five = (FiveRegisterInstruction) instruction;
            int[] available = {
                    five.getRegisterC(), five.getRegisterD(), five.getRegisterE(),
                    five.getRegisterF(), five.getRegisterG()
            };
            require(count >= 0 && count <= available.length,
                    "invoke_register_count_invalid");
            return Arrays.copyOf(available, count);
        }
        throw new ContractFailure("invoke_register_format_unsupported");
    }

    private static FieldReference fieldReference(Instruction instruction) {
        if (!(instruction instanceof ReferenceInstruction)) return null;
        Reference reference = ((ReferenceInstruction) instruction).getReference();
        return reference instanceof FieldReference ? (FieldReference) reference : null;
    }

    private static boolean fieldMatches(FieldReference field, FieldSpec spec) {
        return field != null && spec.owner.equals(field.getDefiningClass())
                && spec.name.equals(field.getName()) && spec.type.equals(field.getType());
    }

    private static String registerOrigin(int register) {
        return "REGISTER:" + register;
    }

    private static String resultOrigin(int callIndex) {
        return "RESULT:" + callIndex;
    }

    private static String stringOrigin(String value, int index) {
        return "STRING:" + value + "#" + index;
    }

    private static String newOrigin(String type, int index) {
        return "NEW:" + type + "#" + index;
    }

    private static String fieldOrigin(FieldReference field, String objectOrigin) {
        return "FIELD:" + field.getDefiningClass() + "->" + field.getName() + ":"
                + field.getType() + "|" + objectOrigin;
    }

    private static String[] initialOrigins(MethodView view) {
        String[] result = new String[view.implementation.getRegisterCount()];
        Arrays.fill(result, OTHER);
        if (view.thisRegister >= 0) result[view.thisRegister] = registerOrigin(view.thisRegister);
        List<? extends CharSequence> types = view.method.getParameterTypes();
        for (int parameter = 0; parameter < view.parameters.length; parameter++) {
            int words = typeWords(types.get(parameter));
            for (int word = 0; word < words; word++) {
                int register = view.parameters[parameter] + word;
                result[register] = registerOrigin(register);
            }
        }
        return result;
    }

    private static String[] transfer(MethodView view, int index, String[] input) {
        String[] output = input.clone();
        Instruction instruction = view.code.get(index).instruction;
        if (!(instruction instanceof OneRegisterInstruction)
                || (instruction.getOpcode().flags & OPCODE_SETS_REGISTER) == 0) {
            return output;
        }
        int destination = ((OneRegisterInstruction) instruction).getRegisterA();
        String opcode = instruction.getOpcode().name();
        boolean wide = (instruction.getOpcode().flags & OPCODE_SETS_WIDE_REGISTER) != 0;
        String low = OTHER;
        String high = OTHER;
        if (opcode.equals("CHECK_CAST")) {
            low = input[destination];
        } else if (opcode.startsWith("MOVE_RESULT")) {
            low = resultOrigin(index - 1);
        } else if (opcode.startsWith("MOVE")
                && instruction instanceof TwoRegisterInstruction) {
            int source = ((TwoRegisterInstruction) instruction).getRegisterB();
            low = input[source];
            if (wide && source + 1 < input.length) high = input[source + 1];
        } else if ((opcode.equals("CONST_STRING") || opcode.equals("CONST_STRING_JUMBO"))
                && instruction instanceof ReferenceInstruction) {
            Reference reference = ((ReferenceInstruction) instruction).getReference();
            if (reference instanceof CharSequence) {
                low = stringOrigin(String.valueOf(reference), index);
            }
        } else if (opcode.startsWith("CONST") && instruction instanceof WideLiteralInstruction) {
            low = "CONST:" + ((WideLiteralInstruction) instruction).getWideLiteral()
                    + "#" + index;
        } else if (opcode.equals("NEW_INSTANCE")
                && instruction instanceof ReferenceInstruction
                && ((ReferenceInstruction) instruction).getReference() instanceof TypeReference) {
            low = newOrigin(((TypeReference) ((ReferenceInstruction) instruction)
                    .getReference()).getType(), index);
        } else if (opcode.startsWith("IGET")
                && instruction instanceof TwoRegisterInstruction) {
            FieldReference field = fieldReference(instruction);
            int object = ((TwoRegisterInstruction) instruction).getRegisterB();
            if (field != null) low = fieldOrigin(field, input[object]);
        }
        output[destination] = low;
        if (wide && destination + 1 < output.length) output[destination + 1] = high;
        return output;
    }

    private static boolean merge(String[] existing, String[] incoming) {
        boolean changed = false;
        for (int register = 0; register < existing.length; register++) {
            String value = existing[register].equals(incoming[register])
                    ? existing[register] : OTHER;
            if (!value.equals(existing[register])) {
                existing[register] = value;
                changed = true;
            }
        }
        return changed;
    }

    private static List<Integer> successors(MethodView view, int index, String code)
            throws ContractFailure {
        Instruction instruction = view.code.get(index).instruction;
        String opcode = instruction.getOpcode().name();
        if (opcode.startsWith("RETURN") || opcode.equals("THROW")) {
            return Collections.emptyList();
        }
        if (opcode.equals("PACKED_SWITCH") || opcode.equals("SPARSE_SWITCH")
                || opcode.endsWith("SWITCH_PAYLOAD") || opcode.equals("FILL_ARRAY_DATA")) {
            throw new ContractFailure(code);
        }
        List<Integer> result = new ArrayList<>();
        if (opcode.startsWith("GOTO") || opcode.startsWith("IF_")) {
            require(instruction instanceof OffsetInstruction, code);
            int target = view.code.get(index).offset
                    + ((OffsetInstruction) instruction).getCodeOffset();
            result.add(view.indexAt(target, code));
            if (opcode.startsWith("GOTO")) return result;
        }
        if (index + 1 < view.code.size()) result.add(index + 1);
        return result;
    }

    private static List<Integer> exceptionSuccessors(
            MethodView view, int index, String code) throws ContractFailure {
        List<Integer> result = new ArrayList<>();
        int offset = view.code.get(index).offset;
        for (Object tryObject : view.implementation.getTryBlocks()) {
            BaseTryBlock tryBlock = (BaseTryBlock) tryObject;
            int start = tryBlock.getStartCodeAddress();
            int end = start + tryBlock.getCodeUnitCount();
            if (offset < start || offset >= end) continue;
            for (Object handlerObject : tryBlock.getExceptionHandlers()) {
                ExceptionHandler handler = (ExceptionHandler) handlerObject;
                int handlerIndex = view.indexAt(handler.getHandlerCodeAddress(), code);
                if (!result.contains(handlerIndex)) result.add(handlerIndex);
            }
        }
        return result;
    }

    private static List<Integer> allSuccessors(MethodView view, int index, String code)
            throws ContractFailure {
        List<Integer> result = new ArrayList<>(successors(view, index, code));
        for (int handler : exceptionSuccessors(view, index, code)) {
            if (!result.contains(handler)) result.add(handler);
        }
        return result;
    }

    private static void ensureOrigins(MethodView view) throws ContractFailure {
        if (view.origins != null) return;
        String[][] inputs = new String[view.code.size()][];
        inputs[0] = initialOrigins(view);
        List<Integer> pending = new ArrayList<>();
        pending.add(0);
        while (!pending.isEmpty()) {
            int index = pending.remove(pending.size() - 1);
            String[] output = transfer(view, index, inputs[index]);
            for (int successor : successors(view, index, "value_flow_control_unsupported")) {
                if (inputs[successor] == null) {
                    inputs[successor] = output.clone();
                    pending.add(successor);
                } else if (merge(inputs[successor], output)) {
                    pending.add(successor);
                }
            }
            for (int handler : exceptionSuccessors(
                    view, index, "value_flow_handler_unsupported")) {
                if (inputs[handler] == null) {
                    inputs[handler] = inputs[index].clone();
                    pending.add(handler);
                } else if (merge(inputs[handler], inputs[index])) {
                    pending.add(handler);
                }
            }
        }
        view.origins = inputs;
    }

    private static String originAt(MethodView view, int index, int register)
            throws ContractFailure {
        ensureOrigins(view);
        require(index >= 0 && index < view.code.size()
                && register >= 0 && register < view.implementation.getRegisterCount(),
                "origin_bounds");
        return view.origins[index] == null ? null : view.origins[index][register];
    }

    private static boolean reachable(
            MethodView view, int start, int destination, int skipped, String code)
            throws ContractFailure {
        if (start < 0 || start >= view.code.size()) return false;
        Set<Integer> visited = new HashSet<>();
        List<Integer> pending = new ArrayList<>();
        pending.add(start);
        while (!pending.isEmpty()) {
            int index = pending.remove(pending.size() - 1);
            if (index == skipped || !visited.add(index)) continue;
            if (index == destination) return true;
            for (int successor : allSuccessors(view, index, code)) {
                if (!visited.contains(successor)) pending.add(successor);
            }
        }
        return false;
    }

    private static boolean dominates(MethodView view, int dominator, int destination, String code)
            throws ContractFailure {
        return reachable(view, 0, destination, -1, code)
                && !reachable(view, 0, destination, dominator, code);
    }

    private static int branchTarget(MethodView view, int branch, String code)
            throws ContractFailure {
        Instruction instruction = view.code.get(branch).instruction;
        require(instruction.getOpcode().name().startsWith("IF_")
                && instruction instanceof OffsetInstruction, code);
        return view.indexAt(view.code.get(branch).offset
                + ((OffsetInstruction) instruction).getCodeOffset(), code);
    }

    private static int oneGuardForOrigin(
            MethodView view, String expectedOrigin, int successIndex, String code)
            throws ContractFailure {
        List<Integer> matches = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            String opcode = instruction.getOpcode().name();
            if (!(opcode.equals("IF_EQZ") || opcode.equals("IF_LEZ"))
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            if (!expectedOrigin.equals(originAt(view, index, register))) continue;
            int target = branchTarget(view, index, code);
            if (dominates(view, index, successIndex, code)
                    && index + 1 < view.code.size()
                    && reachable(view, index + 1, successIndex, -1, code)
                    && !reachable(view, target, successIndex, -1, code)) {
                matches.add(index);
            }
        }
        require(matches.size() == 1, code);
        return matches.get(0);
    }

    private static int oneNullBypassGuard(
            MethodView view, String expectedOrigin, int guardedCall, int join,
            String code) throws ContractFailure {
        List<Integer> matches = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("IF_EQZ")
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            if (!expectedOrigin.equals(originAt(view, index, register))) continue;
            int target = branchTarget(view, index, code);
            if (dominates(view, index, guardedCall, code)
                    && index + 1 < view.code.size()
                    && reachable(view, index + 1, guardedCall, -1, code)
                    && !reachable(view, target, guardedCall, -1, code)
                    && reachable(view, target, join, -1, code)
                    && guardedCall + 1 < view.code.size()
                    && reachable(view, guardedCall + 1, join, -1, code)) {
                matches.add(index);
            }
        }
        require(matches.size() == 1, code);
        return matches.get(0);
    }

    private static int oneNonemptyFallbackGuard(
            MethodView view, String expectedOrigin, int fallbackCall,
            int fallbackResolverCall, int join, String code) throws ContractFailure {
        List<Integer> matches = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("IF_NEZ")
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            if (!expectedOrigin.equals(originAt(view, index, register))) continue;
            int target = branchTarget(view, index, code);
            int fallthrough = index + 1;
            if (fallthrough < view.code.size()
                    && dominates(view, index, fallbackCall, code)
                    && dominates(view, index, fallbackResolverCall, code)
                    && dominates(view, index, join, code)
                    && reachable(view, fallthrough, fallbackCall, -1, code)
                    && !reachable(view, fallthrough, fallbackResolverCall,
                            fallbackCall, code)
                    && !reachable(view, fallthrough, join,
                            fallbackResolverCall, code)
                    && !reachable(view, target, fallbackCall, -1, code)
                    && !reachable(view, target, fallbackResolverCall, -1, code)
                    && reachable(view, target, join, -1, code)
                    && fallbackResolverCall + 1 < view.code.size()
                    && reachable(view, fallbackResolverCall + 1, join, -1, code)) {
                matches.add(index);
            }
        }
        require(matches.size() == 1, code);
        return matches.get(0);
    }

    private static boolean literalAt(
            MethodView view, int index, int register, String value) throws ContractFailure {
        String origin = originAt(view, index, register);
        return origin != null && origin.startsWith("STRING:" + value + "#");
    }

    private static boolean fieldOriginAt(
            MethodView view, int index, int register, FieldSpec field, String objectOrigin)
            throws ContractFailure {
        return ("FIELD:" + field.key() + "|" + objectOrigin)
                .equals(originAt(view, index, register));
    }

    private static int oneReturnWithOrigin(MethodView view, String origin, String code)
            throws ContractFailure {
        List<Integer> matches = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("RETURN_OBJECT")
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            if (origin.equals(originAt(view, index, register))) matches.add(index);
        }
        require(matches.size() == 1, code);
        return matches.get(0);
    }

    private static boolean writesRegister(
            Instruction instruction, int register) {
        if (!(instruction instanceof OneRegisterInstruction)
                || (instruction.getOpcode().flags & OPCODE_SETS_REGISTER) == 0) {
            return false;
        }
        int destination = ((OneRegisterInstruction) instruction).getRegisterA();
        return destination == register
                || ((instruction.getOpcode().flags & OPCODE_SETS_WIDE_REGISTER) != 0
                        && destination + 1 == register);
    }

    private static boolean mergeDefinitions(
            Set<Integer> existing, Set<Integer> incoming) {
        int size = existing.size();
        existing.addAll(incoming);
        return existing.size() != size;
    }

    private static Set<Integer> reachingDefinitions(
            MethodView view, int destination, int register, String code)
            throws ContractFailure {
        List<Set<Integer>> inputs = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) inputs.add(null);
        Set<Integer> entry = new HashSet<>();
        entry.add(-1);
        inputs.set(0, entry);
        List<Integer> pending = new ArrayList<>();
        pending.add(0);
        while (!pending.isEmpty()) {
            int index = pending.remove(pending.size() - 1);
            Set<Integer> input = inputs.get(index);
            Set<Integer> output = new HashSet<>(input);
            if (writesRegister(view.code.get(index).instruction, register)) {
                output.clear();
                output.add(index);
            }
            for (int successor : successors(view, index, code)) {
                Set<Integer> successorInput = inputs.get(successor);
                if (successorInput == null) {
                    inputs.set(successor, new HashSet<>(output));
                    pending.add(successor);
                } else if (mergeDefinitions(successorInput, output)) {
                    pending.add(successor);
                }
            }
            for (int handler : exceptionSuccessors(view, index, code)) {
                Set<Integer> handlerInput = inputs.get(handler);
                if (handlerInput == null) {
                    inputs.set(handler, new HashSet<>(input));
                    pending.add(handler);
                } else if (mergeDefinitions(handlerInput, input)) {
                    pending.add(handler);
                }
            }
        }
        Set<Integer> result = inputs.get(destination);
        require(result != null && !result.isEmpty(), code);
        return result;
    }

    private static Set<Integer> objectSourceDefinitions(
            MethodView view, int destination, int register, String code)
            throws ContractFailure {
        List<int[]> pending = new ArrayList<>();
        pending.add(new int[] { destination, register });
        Set<String> visited = new HashSet<>();
        Set<Integer> terminals = new HashSet<>();
        while (!pending.isEmpty()) {
            int[] state = pending.remove(pending.size() - 1);
            String key = state[0] + ":" + state[1];
            if (!visited.add(key)) continue;
            Set<Integer> definitions = reachingDefinitions(
                    view, state[0], state[1], code);
            for (int definition : definitions) {
                require(definition >= 0, code);
                Instruction instruction = view.code.get(definition).instruction;
                if (instruction.getOpcode().name().startsWith("MOVE_OBJECT")
                        && instruction instanceof TwoRegisterInstruction) {
                    pending.add(new int[] {
                            definition,
                            ((TwoRegisterInstruction) instruction).getRegisterB()
                    });
                } else {
                    terminals.add(definition);
                }
            }
        }
        require(!terminals.isEmpty(), code);
        return terminals;
    }

    private static boolean isExactObjectCallResult(
            MethodView view, int definition, int call) {
        if (definition != call + 1 || definition < 0
                || definition >= view.code.size()) return false;
        Instruction instruction = view.code.get(definition).instruction;
        return instruction.getOpcode().name().equals("MOVE_RESULT_OBJECT")
                && instruction instanceof OneRegisterInstruction;
    }

    private static int requestValiditySuccessDefinition(
            MethodView view, String code) throws ContractFailure {
        List<Integer> returns = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (instruction.getOpcode().name().startsWith("RETURN")) {
                require(instruction.getOpcode().name().equals("RETURN")
                                && instruction instanceof OneRegisterInstruction,
                        code + "_return_kind");
                returns.add(index);
            }
        }
        require(returns.size() == 1, code + "_return_count");
        int returnIndex = returns.get(0);
        int register = ((OneRegisterInstruction) view.code.get(returnIndex).instruction)
                .getRegisterA();
        Set<Integer> definitions = reachingDefinitions(
                view, returnIndex, register, code + "_definition_flow");
        List<Integer> successDefinitions = new ArrayList<>();
        int falseDefinitions = 0;
        for (int definition : definitions) {
            require(definition >= 0, code + "_definition_flow");
            Instruction instruction = view.code.get(definition).instruction;
            require(instruction.getOpcode().name().startsWith("CONST")
                            && instruction instanceof WideLiteralInstruction
                            && writesRegister(instruction, register),
                    code + "_definition_flow");
            long literal = ((WideLiteralInstruction) instruction).getWideLiteral();
            require(literal == 0 || literal == 1, code + "_definition_flow");
            if (literal == 1) successDefinitions.add(definition);
            else falseDefinitions++;
        }
        require(successDefinitions.size() == 1,
                code + "_success_definition_count");
        require(falseDefinitions >= 1, code + "_false_definition_count");
        return successDefinitions.get(0);
    }

    private static boolean isZeroOrigin(String origin) {
        return origin != null && origin.startsWith("CONST:0#");
    }

    private static boolean isExactStringWrite(
            MethodView view, int index, int register, String value) {
        Instruction instruction = view.code.get(index).instruction;
        if (!(instruction instanceof OneRegisterInstruction)
                || !(instruction instanceof ReferenceInstruction)
                || !writesRegister(instruction, register)) {
            return false;
        }
        String opcode = instruction.getOpcode().name();
        if (!(opcode.equals("CONST_STRING") || opcode.equals("CONST_STRING_JUMBO"))) {
            return false;
        }
        Reference reference = ((ReferenceInstruction) instruction).getReference();
        return reference instanceof CharSequence && value.equals(String.valueOf(reference));
    }

    private static void verifyFactory(
            Map<String, ClassDef> classes, CallSpec factory, CallSpec resolvedMediaGetter,
            FieldSpec mediaBackingField, CallSpec mediaPermalink, CallSpec mediaCode,
            CallSpec mediaCaption, CallSpec captionText, CallSpec permalinkResolver,
            CallSpec excerptResolver, CallSpec labelGetter, CallSpec constructor,
            CallSpec getter, CallSpec stringLength, CallSpec currentViewer,
            Evidence evidence)
            throws ContractFailure {
        MethodView view = exactMethod(classes, factory, "factory_method");
        require(classCallCount(classes, factory.owner, currentViewer,
                        "factory_current_viewer_call_absence") == 0,
                "factory_current_viewer_call_absence");
        boolean directMediaAccess = mediaBackingField.owner.equals(mediaPermalink.owner)
                && mediaBackingField.owner.equals(mediaCode.owner)
                && mediaBackingField.owner.equals(mediaCaption.owner);
        int resolvedMediaCall = oneCall(
                view, resolvedMediaGetter, "factory_resolved_media_call_count");
        int[] resolvedMediaRegisters = invocationRegisters(
                view.code.get(resolvedMediaCall).instruction);
        require(resolvedMediaRegisters.length == 1
                        && view.parameters.length == 1
                        && registerOrigin(view.parameters[0]).equals(
                                originAt(view, resolvedMediaCall,
                                        resolvedMediaRegisters[0])),
                "factory_resolved_media_receiver_flow");
        List<Integer> backingReads = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("IGET_OBJECT")
                    || !(instruction instanceof TwoRegisterInstruction)
                    || !fieldMatches(fieldReference(instruction), mediaBackingField)) continue;
            int object = ((TwoRegisterInstruction) instruction).getRegisterB();
            if (resultOrigin(resolvedMediaCall).equals(originAt(view, index, object))) {
                backingReads.add(index);
            }
        }
        int backingRead = -1;
        int backingRegister = -1;
        String mediaReceiverOrigin;
        int receiverReady;
        if (directMediaAccess) {
            require(backingReads.isEmpty(), "factory_media_backing_field_flow");
            List<Integer> modelCasts = new ArrayList<>();
            for (int index = 0; index < view.code.size(); index++) {
                Instruction instruction = view.code.get(index).instruction;
                if (!instruction.getOpcode().name().equals("CHECK_CAST")
                        || !(instruction instanceof OneRegisterInstruction)
                        || !(instruction instanceof ReferenceInstruction)
                        || !(((ReferenceInstruction) instruction).getReference()
                                instanceof TypeReference)) continue;
                String type = ((TypeReference) ((ReferenceInstruction) instruction)
                        .getReference()).getType();
                int register = ((OneRegisterInstruction) instruction).getRegisterA();
                if (mediaBackingField.owner.equals(type)
                        && resultOrigin(resolvedMediaCall).equals(
                                originAt(view, index, register))) {
                    modelCasts.add(index);
                }
            }
            require(modelCasts.size() == 1, "factory_media_model_cast_flow");
            receiverReady = modelCasts.get(0);
            mediaReceiverOrigin = resultOrigin(resolvedMediaCall);
        } else {
            require(backingReads.size() == 1, "factory_media_backing_field_flow");
            backingRead = backingReads.get(0);
            backingRegister = ((TwoRegisterInstruction)
                    view.code.get(backingRead).instruction).getRegisterA();
            mediaReceiverOrigin = fieldOrigin(
                    fieldReference(view.code.get(backingRead).instruction),
                    resultOrigin(resolvedMediaCall));
            receiverReady = backingRead;
        }
        int labelCall = oneCall(view, labelGetter, "factory_label_call_count");
        int[] labelRegisters = invocationRegisters(view.code.get(labelCall).instruction);
        require(labelRegisters.length == 1 && view.parameters.length == 1
                        && registerOrigin(view.parameters[0]).equals(
                                originAt(view, labelCall, labelRegisters[0])),
                "factory_label_receiver_flow");

        int codeCall = oneCall(view, mediaCode, "factory_code_call_count");
        require(view.code.get(codeCall).instruction.getOpcode().name().equals(
                        directMediaAccess ? "INVOKE_VIRTUAL" : "INVOKE_INTERFACE"),
                "factory_code_opcode");
        int[] codeRegisters = invocationRegisters(view.code.get(codeCall).instruction);
        require(codeRegisters.length == 1
                        && mediaReceiverOrigin.equals(
                                originAt(view, codeCall, codeRegisters[0])),
                "factory_code_receiver_flow");

        int mediaCall = oneCall(view, mediaPermalink, "factory_permalink_call_count");
        require(view.code.get(mediaCall).instruction.getOpcode().name().equals(
                        directMediaAccess ? "INVOKE_VIRTUAL" : "INVOKE_INTERFACE"),
                "factory_permalink_opcode");
        int[] mediaRegisters = invocationRegisters(view.code.get(mediaCall).instruction);
        require(mediaRegisters.length == 1
                        && mediaReceiverOrigin.equals(
                                originAt(view, mediaCall, mediaRegisters[0])),
                "factory_permalink_receiver_flow");

        List<Integer> permalinkResolverCalls = callIndexes(view, permalinkResolver);
        require(permalinkResolverCalls.size() == 2,
                "factory_permalink_resolver_call_count");
        int permalinkResolverCall = permalinkResolverCalls.get(0);
        int fallbackPermalinkResolverCall = permalinkResolverCalls.get(1);
        int[] primaryResolverRegisters = invocationRegisters(
                view.code.get(permalinkResolverCall).instruction);
        int[] fallbackResolverRegisters = invocationRegisters(
                view.code.get(fallbackPermalinkResolverCall).instruction);
        require(view.code.get(permalinkResolverCall).instruction.getOpcode().name()
                        .equals("INVOKE_STATIC")
                        && view.code.get(fallbackPermalinkResolverCall).instruction
                                .getOpcode().name().equals("INVOKE_STATIC"),
                "factory_permalink_resolver_opcode");
        require(primaryResolverRegisters.length == 3
                        && fallbackResolverRegisters.length == 3,
                "factory_permalink_resolver_arity");
        require(resultOrigin(labelCall).equals(originAt(
                        view, permalinkResolverCall, primaryResolverRegisters[0])),
                "factory_permalink_primary_label_flow");
        require(literalAt(view, permalinkResolverCall,
                        primaryResolverRegisters[1], ""),
                "factory_permalink_primary_candidate_flow");
        require(resultOrigin(codeCall).equals(originAt(
                        view, permalinkResolverCall, primaryResolverRegisters[2])),
                "factory_permalink_primary_code_flow");
        require(resultOrigin(labelCall).equals(originAt(
                        view, fallbackPermalinkResolverCall,
                        fallbackResolverRegisters[0])),
                "factory_permalink_fallback_label_flow");
        require(resultOrigin(mediaCall).equals(originAt(
                        view, fallbackPermalinkResolverCall,
                        fallbackResolverRegisters[1])),
                "factory_permalink_fallback_candidate_flow");
        require(literalAt(view, fallbackPermalinkResolverCall,
                        fallbackResolverRegisters[2], ""),
                "factory_permalink_fallback_code_flow");

        List<Integer> lengthCalls = callIndexes(view, stringLength);
        require(lengthCalls.size() == 2, "factory_length_count");
        List<Integer> primaryLengthCalls = new ArrayList<>();
        for (int call : lengthCalls) {
            int[] registers = invocationRegisters(view.code.get(call).instruction);
            if (registers.length == 1
                    && resultOrigin(permalinkResolverCall).equals(
                            originAt(view, call, registers[0]))) {
                primaryLengthCalls.add(call);
            }
        }
        require(primaryLengthCalls.size() == 1,
                "factory_permalink_primary_length_flow");
        int primaryLengthCall = primaryLengthCalls.get(0);

        int captionCall = oneCall(view, mediaCaption, "factory_caption_call_count");
        require(view.code.get(captionCall).instruction.getOpcode().name().equals(
                        directMediaAccess ? "INVOKE_VIRTUAL" : "INVOKE_INTERFACE"),
                "factory_caption_opcode");
        int[] captionRegisters = invocationRegisters(view.code.get(captionCall).instruction);
        require(captionRegisters.length == 1
                        && mediaReceiverOrigin.equals(originAt(view, captionCall,
                                captionRegisters[0])),
                "factory_caption_receiver_flow");
        int captionTextCall = oneCall(
                view, captionText, "factory_caption_text_call_count");
        require(view.code.get(captionTextCall).instruction.getOpcode().name()
                        .equals("INVOKE_INTERFACE"),
                "factory_caption_text_opcode");
        int[] captionTextRegisters = invocationRegisters(
                view.code.get(captionTextCall).instruction);
        require(captionTextRegisters.length == 1
                        && resultOrigin(captionCall).equals(
                                originAt(view, captionTextCall, captionTextRegisters[0])),
                "factory_caption_text_receiver_flow");

        int excerptResolverCall = oneCall(
                view, excerptResolver, "factory_excerpt_resolver_call_count");
        require(view.code.get(excerptResolverCall).instruction.getOpcode().name()
                        .equals("INVOKE_STATIC"),
                "factory_excerpt_resolver_opcode");
        int[] excerptResolverRegisters = invocationRegisters(
                view.code.get(excerptResolverCall).instruction);
        require(excerptResolverRegisters.length == 1,
                "factory_excerpt_resolver_arity");
        int excerptInputRegister = excerptResolverRegisters[0];
        Set<Integer> excerptDefinitions = reachingDefinitions(
                view, excerptResolverCall, excerptInputRegister,
                "factory_excerpt_input_flow");
        boolean captionTextDefinition = false;
        int emptyDefinitions = 0;
        for (int definition : excerptDefinitions) {
            if (definition == captionTextCall + 1
                    && writesRegister(view.code.get(definition).instruction,
                            excerptInputRegister)
                    && view.code.get(definition).instruction.getOpcode().name()
                            .equals("MOVE_RESULT_OBJECT")) {
                captionTextDefinition = true;
            } else if (definition >= 0 && isExactStringWrite(
                    view, definition, excerptInputRegister, "")) {
                emptyDefinitions++;
            } else {
                throw new ContractFailure("factory_excerpt_input_flow");
            }
        }
        require(captionTextDefinition && emptyDefinitions >= 1,
                "factory_excerpt_input_flow");
        oneNullBypassGuard(view, resultOrigin(captionCall), captionTextCall,
                excerptResolverCall, "factory_caption_null_bypass_flow");
        require(resolvedMediaCall < receiverReady && receiverReady < codeCall
                        && codeCall < permalinkResolverCall
                        && permalinkResolverCall < primaryLengthCall
                        && primaryLengthCall < mediaCall
                        && mediaCall < fallbackPermalinkResolverCall
                        && fallbackPermalinkResolverCall < captionCall
                        && captionCall < captionTextCall
                        && captionTextCall < excerptResolverCall
                        && (directMediaAccess || backingRegister >= 0),
                "factory_media_call_order");
        int permalinkFallbackGuard = oneNonemptyFallbackGuard(
                view, resultOrigin(primaryLengthCall), mediaCall,
                fallbackPermalinkResolverCall, captionCall,
                "factory_permalink_fallback_guard_flow");
        require(primaryLengthCall < permalinkFallbackGuard
                        && permalinkFallbackGuard < mediaCall,
                "factory_permalink_fallback_guard_order");
        int constructorCall = oneCall(view, constructor, "factory_constructor_count");
        require(view.code.get(constructorCall).instruction.getOpcode().name()
                .equals("INVOKE_DIRECT_RANGE"), "factory_constructor_opcode");
        int[] constructorRegisters = invocationRegisters(
                view.code.get(constructorCall).instruction);
        require(constructorRegisters.length == 7, "factory_constructor_arity");
        Set<Integer> usernameDefinitions = objectSourceDefinitions(
                view, constructorCall, constructorRegisters[2],
                "factory_constructor_username_flow");
        require(usernameDefinitions.size() == 1
                        && usernameDefinitions.contains(labelCall + 1)
                        && isExactObjectCallResult(view, labelCall + 1, labelCall),
                "factory_constructor_username_flow");
        Set<Integer> excerptResultDefinitions = objectSourceDefinitions(
                view, constructorCall, constructorRegisters[4],
                "factory_excerpt_flow");
        require(excerptResultDefinitions.size() == 1
                        && excerptResultDefinitions.contains(excerptResolverCall + 1)
                        && isExactObjectCallResult(
                                view, excerptResolverCall + 1, excerptResolverCall),
                "factory_excerpt_flow");
        Set<Integer> permalinkDefinitions = objectSourceDefinitions(
                view, constructorCall, constructorRegisters[6],
                "factory_permalink_flow");
        require(permalinkDefinitions.size() == 2
                        && permalinkDefinitions.contains(permalinkResolverCall + 1)
                        && permalinkDefinitions.contains(fallbackPermalinkResolverCall + 1)
                        && isExactObjectCallResult(
                                view, permalinkResolverCall + 1,
                                permalinkResolverCall)
                        && isExactObjectCallResult(
                                view, fallbackPermalinkResolverCall + 1,
                                fallbackPermalinkResolverCall),
                "factory_permalink_flow");
        String requestOrigin = originAt(view, constructorCall, constructorRegisters[0]);
        require(requestOrigin != null
                        && requestOrigin.startsWith("NEW:" + constructor.owner + "#"),
                "factory_request_allocation_flow");

        int getterCall = oneCall(view, getter, "factory_getter_count");
        int[] getterRegisters = invocationRegisters(view.code.get(getterCall).instruction);
        require(getterRegisters.length == 1
                        && requestOrigin.equals(originAt(view, getterCall, getterRegisters[0])),
                "factory_getter_receiver_flow");
        List<Integer> requestLengthCalls = new ArrayList<>();
        for (int call : lengthCalls) {
            int[] registers = invocationRegisters(view.code.get(call).instruction);
            if (registers.length == 1
                    && resultOrigin(getterCall).equals(
                            originAt(view, call, registers[0]))) {
                requestLengthCalls.add(call);
            }
        }
        require(requestLengthCalls.size() == 1
                        && requestLengthCalls.get(0) != primaryLengthCall,
                "factory_nonempty_value_flow");
        int lengthCall = requestLengthCalls.get(0);
        int successReturn = oneReturnWithOrigin(
                view, requestOrigin, "factory_success_return_flow");
        oneGuardForOrigin(view, resultOrigin(lengthCall), successReturn,
                "factory_nonempty_guard_flow");
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("RETURN_OBJECT")
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            String returned = originAt(view, index,
                    ((OneRegisterInstruction) instruction).getRegisterA());
            require(requestOrigin.equals(returned) || isZeroOrigin(returned),
                    "factory_return_flow");
        }
        evidence.factoryPermalinkCallOffset = view.code.get(mediaCall).offset;
        evidence.factoryCodeCallOffset = view.code.get(codeCall).offset;
        evidence.factoryPermalinkResolverOffset = view.code.get(permalinkResolverCall).offset;
        evidence.factoryPermalinkFallbackGuardOffset =
                view.code.get(permalinkFallbackGuard).offset;
        evidence.factoryFallbackPermalinkResolverOffset =
                view.code.get(fallbackPermalinkResolverCall).offset;
        evidence.factoryCaptionTextCallOffset = view.code.get(captionTextCall).offset;
        evidence.factoryExcerptResolverOffset = view.code.get(excerptResolverCall).offset;
        evidence.factoryConstructorOffset = view.code.get(constructorCall).offset;
    }

    private static boolean exactDefinitions(
            Set<Integer> observed, int... expected) {
        if (observed.size() != expected.length) return false;
        for (int definition : expected) {
            if (!observed.contains(definition)) return false;
        }
        return true;
    }

    private static boolean exactLiteralDefinition(
            MethodView view, int definition, int register, long expected) {
        if (definition < 0 || definition >= view.code.size()) return false;
        Instruction instruction = view.code.get(definition).instruction;
        return instruction instanceof WideLiteralInstruction
                && writesRegister(instruction, register)
                && ((WideLiteralInstruction) instruction).getWideLiteral() == expected;
    }

    private static void verifyRenderContract(
            Map<String, ClassDef> classes, CallSpec inlineRowRender,
            CallSpec currentViewer, CallSpec ufiButton,
            CallSpec visibilityModifier, CallSpec testTag,
            CallSpec modifierComposed, int expectedDefaultMask,
            Evidence evidence) throws ContractFailure {
        MethodView row = exactMethod(classes, inlineRowRender, "inline_row_render_method");
        require(classCallCount(classes, inlineRowRender.owner, currentViewer,
                        "row_current_viewer_call_absence") == 0,
                "row_current_viewer_call_absence");

        int visibilityCall = oneCall(
                row, visibilityModifier, "row_visibility_modifier_call_count");
        int testTagCall = oneCall(row, testTag, "row_test_tag_call_count");
        int modifierComposedCall = oneCall(
                row, modifierComposed, "row_modifier_composed_call_count");
        int ufiButtonCall = oneCall(row, ufiButton, "row_ufi_button_call_count");
        require(visibilityCall < testTagCall
                        && testTagCall < modifierComposedCall
                        && modifierComposedCall < ufiButtonCall,
                "row_modifier_call_order");

        int[] visibilityRegisters = invocationRegisters(
                row.code.get(visibilityCall).instruction);
        int[] testTagRegisters = invocationRegisters(
                row.code.get(testTagCall).instruction);
        int[] modifierComposedRegisters = invocationRegisters(
                row.code.get(modifierComposedCall).instruction);
        int[] ufiButtonRegisters = invocationRegisters(
                row.code.get(ufiButtonCall).instruction);
        require(visibilityRegisters.length == 2
                        && testTagRegisters.length == 2
                        && modifierComposedRegisters.length == 3
                        && ufiButtonRegisters.length == 22,
                "row_modifier_invoke_register_layout");
        require(literalAt(row, testTagCall, testTagRegisters[1],
                        "threadsmod_inline_block"),
                "row_test_tag_literal");

        int visibilityResult = visibilityCall + 1;
        int testTagResult = testTagCall + 1;
        int modifierComposedResult = modifierComposedCall + 1;
        require(isExactObjectCallResult(row, visibilityResult, visibilityCall)
                        && exactDefinitions(objectSourceDefinitions(
                                row, testTagCall, testTagRegisters[0],
                                "row_visibility_modifier_flow"), visibilityResult),
                "row_visibility_modifier_flow");
        require(isExactObjectCallResult(row, testTagResult, testTagCall)
                        && exactDefinitions(objectSourceDefinitions(
                                row, modifierComposedCall,
                                modifierComposedRegisters[0],
                                "row_test_tag_modifier_flow"), testTagResult),
                "row_test_tag_modifier_flow");
        require(isExactObjectCallResult(
                        row, modifierComposedResult, modifierComposedCall)
                        && exactDefinitions(objectSourceDefinitions(
                                row, ufiButtonCall, ufiButtonRegisters[2],
                                "row_ufi_modifier_flow"),
                                testTagResult, modifierComposedResult),
                "row_ufi_modifier_flow");
        require(dominates(row, visibilityCall, testTagCall,
                            "row_modifier_control_flow")
                        && dominates(row, testTagCall, modifierComposedCall,
                            "row_modifier_control_flow")
                        && dominates(row, testTagCall, ufiButtonCall,
                            "row_modifier_control_flow")
                        && !dominates(row, modifierComposedCall, ufiButtonCall,
                            "row_modifier_control_flow")
                        && reachable(row, testTagResult + 1, ufiButtonCall,
                            modifierComposedResult, "row_modifier_control_flow")
                        && reachable(row, modifierComposedResult, ufiButtonCall,
                            -1, "row_modifier_control_flow"),
                "row_modifier_control_flow");

        Set<Integer> maskDefinitions = reachingDefinitions(
                row, ufiButtonCall, ufiButtonRegisters[12],
                "row_ufi_default_mask_flow");
        require(maskDefinitions.size() == 1,
                "row_ufi_default_mask_flow");
        int maskDefinition = maskDefinitions.iterator().next();
        require(exactLiteralDefinition(row, maskDefinition,
                        ufiButtonRegisters[12], expectedDefaultMask),
                "row_ufi_default_mask_literal");

        evidence.rowVisibilityModifierOffset = row.code.get(visibilityCall).offset;
        evidence.rowTestTagOffset = row.code.get(testTagCall).offset;
        evidence.rowModifierComposedOffset = row.code.get(modifierComposedCall).offset;
        evidence.rowUfiButtonOffset = row.code.get(ufiButtonCall).offset;
        evidence.rowUfiButtonDefaultMask = expectedDefaultMask;
    }

    private static void verifyRequest(
            Map<String, ClassDef> classes, CallSpec constructor, CallSpec sanitizer,
            FieldSpec permalinkField, CallSpec validity, CallSpec baseValidity,
            CallSpec getter, CallSpec stringLength, Evidence evidence)
            throws ContractFailure {
        MethodView constructorView = exactMethod(classes, constructor, "request_constructor");
        require(constructorView.parameters.length == 6,
                "request_constructor_parameter_count");
        int sanitizerCall = oneCall(
                constructorView, sanitizer, "request_sanitizer_call_count");
        int[] sanitizerRegisters = invocationRegisters(
                constructorView.code.get(sanitizerCall).instruction);
        require(sanitizerRegisters.length == 2
                        && registerOrigin(constructorView.parameters[5]).equals(
                                originAt(constructorView, sanitizerCall,
                                        sanitizerRegisters[0])),
                "request_permalink_sanitizer_flow");
        FieldSpec usernameField = new FieldSpec(
                constructor.owner, "profileUsername", STRING);
        require(fieldOriginAt(constructorView, sanitizerCall, sanitizerRegisters[1],
                        usernameField, registerOrigin(constructorView.thisRegister)),
                "request_sanitizer_username_flow");

        List<Integer> stores = new ArrayList<>();
        for (int index = 0; index < constructorView.code.size(); index++) {
            Instruction instruction = constructorView.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("IPUT_OBJECT")
                    || !(instruction instanceof TwoRegisterInstruction)
                    || !fieldMatches(fieldReference(instruction), permalinkField)) continue;
            int value = ((TwoRegisterInstruction) instruction).getRegisterA();
            int object = ((TwoRegisterInstruction) instruction).getRegisterB();
            require(registerOrigin(constructorView.thisRegister).equals(
                    originAt(constructorView, index, object)),
                    "request_permalink_store_receiver_flow");
            stores.add(index);
        }
        require(stores.size() == 1, "request_permalink_store_count");
        int storedValue = ((TwoRegisterInstruction) constructorView.code
                .get(stores.get(0)).instruction).getRegisterA();
        require(resultOrigin(sanitizerCall).equals(
                        originAt(constructorView, stores.get(0), storedValue)),
                "request_permalink_storage_flow");
        ClassDef requestClass = classes.get(permalinkField.owner);
        require(requestClass != null, "request_permalink_field_class");
        int fieldDefinitions = 0;
        boolean finalField = false;
        for (Object fieldObject : requestClass.getInstanceFields()) {
            Field field = (Field) fieldObject;
            if (!permalinkField.name.equals(field.getName())
                    || !permalinkField.type.equals(field.getType())) continue;
            fieldDefinitions++;
            finalField = (field.getAccessFlags() & 0x10) != 0;
        }
        require(fieldDefinitions == 1 && finalField,
                "request_permalink_field_immutable");
        int classWideWrites = 0;
        for (Method method : methods(requestClass)) {
            MethodImplementation implementation = method.getImplementation();
            if (implementation == null) continue;
            for (Object instructionObject : implementation.getInstructions()) {
                Instruction instruction = (Instruction) instructionObject;
                if (instruction.getOpcode().name().equals("IPUT_OBJECT")
                        && fieldMatches(fieldReference(instruction), permalinkField)) {
                    classWideWrites++;
                }
            }
        }
        require(classWideWrites == 1, "request_permalink_field_write_count");
        evidence.constructorSanitizerOffset = constructorView.code.get(sanitizerCall).offset;
        evidence.constructorStoreOffset = constructorView.code.get(stores.get(0)).offset;

        MethodView getterView = exactMethod(classes, getter, "request_getter");
        int getterReturn = oneReturnWithOrigin(getterView,
                "FIELD:" + permalinkField.key() + "|"
                        + registerOrigin(getterView.thisRegister),
                "request_getter_field_flow");
        require(getterReturn >= 0, "request_getter_field_flow");

        MethodView validityView = exactMethod(classes, validity, "request_validity");
        int baseCall = oneCall(validityView, baseValidity,
                "request_base_validity_call_count");
        int[] baseRegisters = invocationRegisters(validityView.code.get(baseCall).instruction);
        require(baseRegisters.length == 1
                        && registerOrigin(validityView.thisRegister).equals(
                                originAt(validityView, baseCall, baseRegisters[0])),
                "request_base_validity_receiver_flow");
        int lengthCall = oneCall(validityView, stringLength,
                "request_validity_length_count");
        int[] lengthRegisters = invocationRegisters(validityView.code.get(lengthCall).instruction);
        require(lengthRegisters.length == 1
                        && fieldOriginAt(validityView, lengthCall, lengthRegisters[0],
                                permalinkField, registerOrigin(validityView.thisRegister)),
                "request_validity_permalink_flow");
        require(!validityView.implementation.getTryBlocks().iterator().hasNext(),
                "request_validity_exception_flow");
        int successDefinition = requestValiditySuccessDefinition(validityView,
                "request_validity");
        int baseGuard = oneGuardForOrigin(validityView, resultOrigin(baseCall),
                successDefinition,
                "request_base_validity_guard_flow");
        int permalinkGuard = oneGuardForOrigin(validityView, resultOrigin(lengthCall),
                successDefinition, "request_new_queue_validity_flow");
        int conditionalBranches = 0;
        for (int index = 0; index < validityView.code.size(); index++) {
            Instruction instruction = validityView.code.get(index).instruction;
            String opcode = instruction.getOpcode().name();
            require(!opcode.equals("PACKED_SWITCH") && !opcode.equals("SPARSE_SWITCH")
                            && !opcode.endsWith("SWITCH_PAYLOAD"),
                    "request_validity_control_flow");
            if (!opcode.startsWith("IF_")) continue;
            conditionalBranches++;
            require(index == baseGuard || index == permalinkGuard,
                    "request_validity_control_flow");
        }
        require(conditionalBranches == 2,
                "request_validity_control_flow");
        evidence.validityBaseGuardOffset = validityView.code.get(baseGuard).offset;
        evidence.validityPermalinkGuardOffset = validityView.code.get(permalinkGuard).offset;
    }

    private static List<Integer> jsonPutCallsForLiteral(
            MethodView view, CallSpec jsonPut, String literal) throws ContractFailure {
        List<Integer> result = new ArrayList<>();
        for (int index : callIndexes(view, jsonPut)) {
            int[] registers = invocationRegisters(view.code.get(index).instruction);
            require(registers.length == 3, "payload_json_put_arity");
            if (literalAt(view, index, registers[1], literal)) result.add(index);
        }
        return result;
    }

    private static int getterProducingOrigin(
            MethodView view, CallSpec getter, FieldSpec requestField, String origin,
            String code) throws ContractFailure {
        List<Integer> matches = new ArrayList<>();
        for (int getterCall : callIndexes(view, getter)) {
            int[] registers = invocationRegisters(view.code.get(getterCall).instruction);
            if (registers.length == 1
                    && fieldOriginAt(view, getterCall, registers[0], requestField,
                            registerOrigin(view.thisRegister))
                    && resultOrigin(getterCall).equals(origin)) {
                matches.add(getterCall);
            }
        }
        require(matches.size() == 1, code);
        return matches.get(0);
    }

    private static void verifyPayload(
            Map<String, ClassDef> classes, CallSpec payloadToJson,
            FieldSpec payloadRequestField, CallSpec getter, CallSpec jsonPut,
            CallSpec jsonArrayPut, CallSpec stringLength, CallSpec jsonArrayConstructor,
            Evidence evidence)
            throws ContractFailure {
        MethodView view = exactMethod(classes, payloadToJson, "payload_to_json");
        List<Integer> targetCalls = jsonPutCallsForLiteral(view, jsonPut, "targetUrl");
        require(targetCalls.size() == 1, "payload_target_url_count");
        int targetCall = targetCalls.get(0);
        int[] targetRegisters = invocationRegisters(view.code.get(targetCall).instruction);
        String rootOrigin = originAt(view, targetCall, targetRegisters[0]);
        require(rootOrigin != null
                        && rootOrigin.startsWith("NEW:Lorg/json/JSONObject;#"),
                "payload_root_flow");
        CallSpec payloadValidity = new CallSpec(payloadToJson.owner, "isValid", "()Z");
        int payloadValidityCall = oneCall(
                view, payloadValidity, "payload_validity_call_count");
        int[] payloadValidityRegisters = invocationRegisters(
                view.code.get(payloadValidityCall).instruction);
        require(payloadValidityRegisters.length == 1
                        && registerOrigin(view.thisRegister).equals(
                                originAt(view, payloadValidityCall,
                                        payloadValidityRegisters[0])),
                "payload_validity_receiver_flow");
        List<Integer> payloadValidityGuards = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("IF_NEZ")
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            if (resultOrigin(payloadValidityCall).equals(
                    originAt(view, index, register))) {
                payloadValidityGuards.add(index);
            }
        }
        require(payloadValidityGuards.size() == 1,
                "payload_validity_guard_flow");
        int payloadValidityGuard = payloadValidityGuards.get(0);
        getterProducingOrigin(view, getter, payloadRequestField,
                originAt(view, targetCall, targetRegisters[2]),
                "payload_target_url_flow");

        List<Integer> arrayPuts = callIndexes(view, jsonArrayPut);
        require(arrayPuts.size() == 1, "payload_evidence_count");
        int arrayPut = arrayPuts.get(0);
        int[] arrayRegisters = invocationRegisters(view.code.get(arrayPut).instruction);
        require(arrayRegisters.length == 2, "payload_evidence_put_arity");
        getterProducingOrigin(view, getter, payloadRequestField,
                originAt(view, arrayPut, arrayRegisters[1]),
                "payload_evidence_flow");
        String arrayOrigin = originAt(view, arrayPut, arrayRegisters[0]);
        require(arrayOrigin != null && arrayOrigin.startsWith("NEW:Lorg/json/JSONArray;#"),
                "payload_evidence_array_flow");
        int arrayConstructor = oneCall(view, jsonArrayConstructor,
                "payload_evidence_array_constructor_count");
        int[] arrayConstructorRegisters = invocationRegisters(
                view.code.get(arrayConstructor).instruction);
        require(arrayConstructorRegisters.length == 1
                        && arrayOrigin.equals(originAt(view, arrayConstructor,
                                arrayConstructorRegisters[0])),
                "payload_evidence_array_constructor_flow");

        List<Integer> evidenceCalls = jsonPutCallsForLiteral(view, jsonPut, "evidence");
        require(evidenceCalls.size() == 1, "payload_evidence_container_count");
        int evidenceCall = evidenceCalls.get(0);
        int[] evidenceRegisters = invocationRegisters(
                view.code.get(evidenceCall).instruction);
        require(rootOrigin.equals(originAt(view, evidenceCall, evidenceRegisters[0])),
                "payload_root_flow");
        require(arrayOrigin.equals(originAt(view, evidenceCall, evidenceRegisters[2])),
                "payload_evidence_container_flow");
        List<Integer> rootReturns = new ArrayList<>();
        List<Integer> successRootReturns = new ArrayList<>();
        List<Integer> allObjectReturns = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("RETURN_OBJECT")
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            allObjectReturns.add(index);
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            if (!rootOrigin.equals(originAt(view, index, register))) continue;
            rootReturns.add(index);
            if (dominates(view, targetCall, index, "payload_root_flow")
                    && dominates(view, evidenceCall, index, "payload_root_flow")
                    && evidenceCall + 1 < view.code.size()
                    && reachable(view, evidenceCall + 1, index, -1,
                            "payload_root_flow")) {
                successRootReturns.add(index);
            }
        }
        require(successRootReturns.size() == 1, "payload_root_flow");
        int successRootReturn = successRootReturns.get(0);
        require(rootReturns.size() == 2, "payload_root_flow");
        int earlyRootReturn = rootReturns.get(0) == successRootReturn
                ? rootReturns.get(1) : rootReturns.get(0);
        int validTarget = branchTarget(
                view, payloadValidityGuard, "payload_validity_guard_flow");
        require(dominates(view, payloadValidityGuard, targetCall,
                            "payload_validity_guard_flow")
                        && dominates(view, payloadValidityGuard, evidenceCall,
                            "payload_validity_guard_flow")
                        && reachable(view, validTarget, targetCall, -1,
                            "payload_validity_guard_flow")
                        && payloadValidityGuard + 1 < view.code.size()
                        && reachable(view, payloadValidityGuard + 1, earlyRootReturn, -1,
                            "payload_validity_guard_flow")
                        && !reachable(view, payloadValidityGuard + 1, targetCall, -1,
                            "payload_validity_guard_flow")
                        && !reachable(view, validTarget, earlyRootReturn, -1,
                            "payload_validity_guard_flow"),
                "payload_validity_guard_flow");
        for (int rootReturn : rootReturns) {
            if (rootReturn == successRootReturn) continue;
            require(!reachable(view, evidenceCall + 1, rootReturn, -1,
                            "payload_root_flow"),
                    "payload_root_flow");
        }
        require(allObjectReturns.size() == 3, "payload_return_count");
        List<Integer> catchReturns = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().equals("RETURN_OBJECT")
                    || !(instruction instanceof OneRegisterInstruction)
                    || index == successRootReturn || index == earlyRootReturn) continue;
            String returned = originAt(view, index,
                    ((OneRegisterInstruction) instruction).getRegisterA());
            require(returned != null
                            && returned.startsWith("NEW:Lorg/json/JSONObject;#")
                            && !rootOrigin.equals(returned),
                    "payload_catch_root_flow");
            catchReturns.add(index);
        }
        require(catchReturns.size() == 1, "payload_catch_root_flow");
        Set<Integer> handlers = new HashSet<>();
        for (Object tryObject : view.implementation.getTryBlocks()) {
            BaseTryBlock tryBlock = (BaseTryBlock) tryObject;
            for (Object handlerObject : tryBlock.getExceptionHandlers()) {
                ExceptionHandler handler = (ExceptionHandler) handlerObject;
                handlers.add(view.indexAt(handler.getHandlerCodeAddress(),
                        "payload_catch_root_flow"));
            }
        }
        require(handlers.size() == 1, "payload_catch_root_flow");
        int handler = handlers.iterator().next();
        int catchReturn = catchReturns.get(0);
        require(reachable(view, handler, catchReturn, -1,
                            "payload_catch_root_flow")
                        && !reachable(view, handler, successRootReturn, -1,
                            "payload_catch_root_flow")
                        && !reachable(view, handler, earlyRootReturn, -1,
                            "payload_catch_root_flow"),
                "payload_catch_root_flow");
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!instruction.getOpcode().name().startsWith("INVOKE_")) continue;
            int[] registers = invocationRegisters(instruction);
            for (int argument = 0; argument < registers.length; argument++) {
                if (!arrayOrigin.equals(originAt(view, index, registers[argument]))) continue;
                boolean reviewedUse = (index == arrayConstructor && argument == 0)
                        || (index == arrayPut && argument == 0)
                        || (index == evidenceCall && argument == 2);
                require(reviewedUse, "payload_evidence_array_use_flow");
            }
        }

        List<Integer> getterCalls = callIndexes(view, getter);
        require(getterCalls.size() == 3, "payload_permalink_getter_count");
        int guardedLengthCall = -1;
        for (int lengthCall : callIndexes(view, stringLength)) {
            int[] lengthRegisters = invocationRegisters(view.code.get(lengthCall).instruction);
            if (lengthRegisters.length != 1) continue;
            String lengthReceiver = originAt(view, lengthCall, lengthRegisters[0]);
            for (int getterCall : getterCalls) {
                if (resultOrigin(getterCall).equals(lengthReceiver)) {
                    int[] getterRegisters = invocationRegisters(
                            view.code.get(getterCall).instruction);
                    if (getterRegisters.length == 1
                            && fieldOriginAt(view, getterCall, getterRegisters[0],
                                    payloadRequestField,
                                    registerOrigin(view.thisRegister))) {
                        require(guardedLengthCall < 0,
                                "payload_evidence_length_count");
                        guardedLengthCall = lengthCall;
                    }
                }
            }
        }
        require(guardedLengthCall >= 0, "payload_evidence_length_flow");
        oneGuardForOrigin(view, resultOrigin(guardedLengthCall), arrayPut,
                "payload_evidence_nonempty_guard_flow");
        evidence.payloadTargetUrlOffset = view.code.get(targetCall).offset;
        evidence.payloadEvidenceValueOffset = view.code.get(arrayPut).offset;
        evidence.payloadEvidenceContainerOffset = view.code.get(evidenceCall).offset;
    }

    private static void verifyQueueBoundaries(
            Map<String, ClassDef> classes, CallSpec validity,
            CallSpec controllerQueue, CallSpec clientQueue, CallSpec threadStart,
            Evidence evidence) throws ContractFailure {
        MethodView controller = exactMethod(classes, controllerQueue,
                "controller_queue_method");
        require(controller.parameters.length == 5,
                "controller_queue_parameter_count");
        int controllerValidityCall = oneCall(controller, validity,
                "controller_new_queue_validity_call_count");
        int[] controllerValidityRegisters = invocationRegisters(
                controller.code.get(controllerValidityCall).instruction);
        require(controllerValidityRegisters.length == 1
                        && registerOrigin(controller.parameters[2]).equals(
                                originAt(controller, controllerValidityCall,
                                        controllerValidityRegisters[0])),
                "controller_new_queue_validity_receiver_flow");
        int clientCallFromController = oneCall(controller, clientQueue,
                "controller_client_queue_call_count");
        int controllerGuard = oneGuardForOrigin(
                controller, resultOrigin(controllerValidityCall),
                clientCallFromController,
                "controller_new_queue_validity_guard_flow");

        MethodView client = exactMethod(classes, clientQueue, "client_queue_method");
        require(client.parameters.length == 5, "client_queue_parameter_count");
        int clientValidityCall = oneCall(client, validity,
                "client_new_queue_validity_call_count");
        int[] clientValidityRegisters = invocationRegisters(
                client.code.get(clientValidityCall).instruction);
        require(clientValidityRegisters.length == 1
                        && registerOrigin(client.parameters[2]).equals(
                                originAt(client, clientValidityCall,
                                        clientValidityRegisters[0])),
                "client_new_queue_validity_receiver_flow");
        int startCall = oneCall(client, threadStart,
                "client_persistence_thread_start_count");
        int clientGuard = oneGuardForOrigin(
                client, resultOrigin(clientValidityCall), startCall,
                "client_new_queue_validity_guard_flow");
        evidence.controllerValidityGuardOffset = controller.code
                .get(controllerGuard).offset;
        evidence.clientValidityGuardOffset = client.code.get(clientGuard).offset;
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
        if (args.length != 33) {
            System.err.println("usage: APK FACTORY_METHOD RESOLVED_MEDIA_GETTER MEDIA_BACKING_FIELD "
                    + "MEDIA_PERMALINK_METHOD MEDIA_CAPTION_METHOD REQUEST_CTOR "
                    + "SANITIZER_METHOD REQUEST_PERMALINK_FIELD NEW_QUEUE_VALIDITY_METHOD "
                    + "BASE_VALIDITY_METHOD REQUEST_GETTER PAYLOAD_TO_JSON PAYLOAD_REQUEST_FIELD "
                    + "JSON_PUT JSON_ARRAY_PUT STRING_LENGTH CONTROLLER_QUEUE "
                    + "CLIENT_QUEUE THREAD_START JSON_ARRAY_CONSTRUCTOR MEDIA_CODE_METHOD "
                    + "CAPTION_TEXT_METHOD PERMALINK_RESOLVER EXCERPT_RESOLVER LABEL_GETTER "
                    + "INLINE_ROW_RENDER CURRENT_VIEWER_METHOD UFI_BUTTON_METHOD "
                    + "VISIBILITY_MODIFIER_METHOD TEST_TAG_METHOD MODIFIER_COMPOSED_METHOD "
                    + "UFI_BUTTON_DEFAULT_MASK");
            System.exit(2);
        }
        try {
            CallSpec factory = CallSpec.parse(args[1], "factory_reference_invalid");
            CallSpec resolvedMediaGetter = CallSpec.parse(
                    args[2], "resolved_media_getter_reference_invalid");
            FieldSpec mediaBackingField = FieldSpec.parse(
                    args[3], "media_backing_field_reference_invalid");
            CallSpec mediaPermalink = CallSpec.parse(
                    args[4], "media_permalink_reference_invalid");
            CallSpec mediaCaption = CallSpec.parse(
                    args[5], "media_caption_reference_invalid");
            CallSpec constructor = CallSpec.parse(args[6], "constructor_reference_invalid");
            CallSpec sanitizer = CallSpec.parse(args[7], "sanitizer_reference_invalid");
            FieldSpec permalinkField = FieldSpec.parse(
                    args[8], "permalink_field_reference_invalid");
            CallSpec validity = CallSpec.parse(args[9], "validity_reference_invalid");
            CallSpec baseValidity = CallSpec.parse(
                    args[10], "base_validity_reference_invalid");
            CallSpec getter = CallSpec.parse(args[11], "getter_reference_invalid");
            CallSpec payloadToJson = CallSpec.parse(
                    args[12], "payload_reference_invalid");
            FieldSpec payloadRequestField = FieldSpec.parse(
                    args[13], "payload_request_field_reference_invalid");
            CallSpec jsonPut = CallSpec.parse(args[14], "json_put_reference_invalid");
            CallSpec jsonArrayPut = CallSpec.parse(
                    args[15], "json_array_put_reference_invalid");
            CallSpec stringLength = CallSpec.parse(
                    args[16], "string_length_reference_invalid");
            CallSpec controllerQueue = CallSpec.parse(
                    args[17], "controller_queue_reference_invalid");
            CallSpec clientQueue = CallSpec.parse(
                    args[18], "client_queue_reference_invalid");
            CallSpec threadStart = CallSpec.parse(
                    args[19], "thread_start_reference_invalid");
            CallSpec jsonArrayConstructor = CallSpec.parse(
                    args[20], "json_array_constructor_reference_invalid");
            CallSpec mediaCode = CallSpec.parse(
                    args[21], "media_code_reference_invalid");
            CallSpec captionText = CallSpec.parse(
                    args[22], "caption_text_reference_invalid");
            CallSpec permalinkResolver = CallSpec.parse(
                    args[23], "permalink_resolver_reference_invalid");
            CallSpec excerptResolver = CallSpec.parse(
                    args[24], "excerpt_resolver_reference_invalid");
            CallSpec labelGetter = CallSpec.parse(
                    args[25], "label_getter_reference_invalid");
            CallSpec inlineRowRender = CallSpec.parse(
                    args[26], "inline_row_render_reference_invalid");
            CallSpec currentViewer = CallSpec.parse(
                    args[27], "current_viewer_reference_invalid");
            CallSpec ufiButton = CallSpec.parse(
                    args[28], "ufi_button_reference_invalid");
            CallSpec visibilityModifier = CallSpec.parse(
                    args[29], "visibility_modifier_reference_invalid");
            CallSpec testTag = CallSpec.parse(
                    args[30], "test_tag_reference_invalid");
            CallSpec modifierComposed = CallSpec.parse(
                    args[31], "modifier_composed_reference_invalid");
            int ufiButtonDefaultMask;
            try {
                ufiButtonDefaultMask = Integer.parseInt(args[32]);
            } catch (NumberFormatException invalidMask) {
                throw new ContractFailure("ufi_default_mask_expectation_invalid");
            }
            require(ufiButtonDefaultMask == 0xf700,
                    "ufi_default_mask_expectation_invalid");
            require(constructor.owner.equals(permalinkField.owner)
                            && constructor.owner.equals(validity.owner)
                            && constructor.owner.equals(baseValidity.owner)
                            && constructor.owner.equals(getter.owner)
                            && constructor.owner.equals(permalinkResolver.owner)
                            && constructor.owner.equals(excerptResolver.owner),
                    "request_reference_owner_mismatch");
            require(resolvedMediaGetter.owner.equals(labelGetter.owner),
                    "inline_request_reference_owner_mismatch");
            require(payloadToJson.owner.equals(payloadRequestField.owner),
                    "payload_reference_owner_mismatch");
            boolean directMediaAccess = mediaBackingField.owner.equals(mediaPermalink.owner)
                    && mediaBackingField.owner.equals(mediaCode.owner)
                    && mediaBackingField.owner.equals(mediaCaption.owner);
            boolean legacyMediaAccess = !directMediaAccess
                    && mediaPermalink.owner.equals(mediaCode.owner)
                    && mediaPermalink.owner.equals(mediaCaption.owner);
            require(legacyMediaAccess != directMediaAccess
                            && mediaPermalink.descriptor.equals("()" + STRING)
                            && mediaCode.descriptor.equals("()" + STRING)
                            && mediaCaption.descriptor.startsWith("()L")
                            && mediaCaption.descriptor.endsWith(";")
                            && captionText.owner.equals(mediaCaption.descriptor.substring(2))
                            && captionText.descriptor.equals("()" + STRING),
                    "media_reference_layout_mismatch");
            require(constructor.descriptor.equals(
                            "(" + STRING + STRING + STRING + STRING + STRING + STRING + ")V")
                            && sanitizer.descriptor.equals("(" + STRING + STRING + ")" + STRING)
                            && permalinkResolver.descriptor.equals(
                                    "(" + STRING + STRING + STRING + ")" + STRING)
                            && excerptResolver.descriptor.equals("(" + STRING + ")" + STRING)
                            && labelGetter.descriptor.equals("()" + STRING)
                            && permalinkField.type.equals(STRING)
                            && validity.descriptor.equals("()Z")
                            && baseValidity.descriptor.equals("()Z")
                            && getter.descriptor.equals("()" + STRING)
                            && payloadToJson.descriptor.equals("()Lorg/json/JSONObject;")
                            && payloadRequestField.type.equals(constructor.owner)
                            && jsonPut.descriptor.equals(
                                    "(" + STRING + "Ljava/lang/Object;)Lorg/json/JSONObject;")
                            && jsonArrayPut.descriptor.equals(
                                    "(Ljava/lang/Object;)Lorg/json/JSONArray;")
                            && stringLength.descriptor.equals("()I"),
                    "reference_descriptor_mismatch");
            require(inlineRowRender.owner.equals(
                            "Lthreadsmod/inlinecontrol/InlineActionRowAdapter;")
                            && inlineRowRender.name.equals("render")
                            && inlineRowRender.descriptor.endsWith(")V")
                            && currentViewer.owner.equals(
                                    "Lthreadsmod/autoblock/AutoBlockSync;")
                            && currentViewer.name.equals("getCurrentViewer")
                            && currentViewer.descriptor.equals("()" + STRING)
                            && visibilityModifier.descriptor.equals(
                                    "(LX/08ub;Lkotlin/jvm/functions/Function1;)LX/08ub;")
                            && testTag.descriptor.equals(
                                    "(LX/08ub;" + STRING + ")LX/08ub;")
                            && modifierComposed.descriptor.equals(
                                    "(LX/08ub;Lkotlin/jvm/functions/Function1;"
                                            + "Lkotlin/jvm/functions/Function3;)LX/08ub;")
                            && ufiButton.descriptor.equals(
                                    "(LX/09jq;LX/09dm;LX/08ub;" + STRING + STRING
                                            + "Lkotlin/jvm/functions/Function0;"
                                            + "Lkotlin/jvm/functions/Function0;FIIIIIJJZZZZZ)V"),
                    "render_guard_reference_mismatch");
            require(controllerQueue.descriptor.equals(
                            "(Landroid/app/Activity;" + STRING + constructor.owner
                                    + STRING
                                    + "Lthreadsmod/reporting/ReportResultCallback;)V")
                            && clientQueue.descriptor.equals(
                                    "(Landroid/content/Context;" + STRING
                                    + constructor.owner + STRING
                                    + "Lthreadsmod/reporting/ReportResultCallback;)V")
                            && threadStart.descriptor.equals("()V"),
                    "queue_reference_descriptor_mismatch");
            require(jsonArrayConstructor.owner.equals("Lorg/json/JSONArray;")
                            && jsonArrayConstructor.name.equals("<init>")
                            && jsonArrayConstructor.descriptor.equals("()V"),
                    "json_array_constructor_reference_mismatch");

            Map<String, ClassDef> classes = readPrimaryDex(args[0]);
            Evidence evidence = new Evidence();
            verifyFactory(classes, factory, resolvedMediaGetter, mediaBackingField,
                    mediaPermalink, mediaCode, mediaCaption, captionText,
                    permalinkResolver, excerptResolver, labelGetter, constructor,
                    getter, stringLength, currentViewer, evidence);
            verifyRenderContract(classes, inlineRowRender, currentViewer,
                    ufiButton, visibilityModifier, testTag, modifierComposed,
                    ufiButtonDefaultMask, evidence);
            verifyRequest(classes, constructor, sanitizer, permalinkField, validity,
                    baseValidity, getter, stringLength, evidence);
            verifyPayload(classes, payloadToJson, payloadRequestField, getter,
                    jsonPut, jsonArrayPut, stringLength, jsonArrayConstructor,
                    evidence);
            verifyQueueBoundaries(classes, validity, controllerQueue, clientQueue,
                    threadStart, evidence);
            System.out.println("{\"schemaVersion\":1,\"status\":\"passed\","
                    + "\"contract\":\"" + CONTRACT + "\",\"dex\":\""
                    + PRIMARY_DEX + "\",\"factory\":{\"permalinkCallOffset\":"
                    + evidence.factoryPermalinkCallOffset + ",\"codeCallOffset\":"
                    + evidence.factoryCodeCallOffset + ",\"permalinkResolverOffset\":"
                    + evidence.factoryPermalinkResolverOffset
                    + ",\"permalinkFallbackGuardOffset\":"
                    + evidence.factoryPermalinkFallbackGuardOffset
                    + ",\"fallbackPermalinkResolverOffset\":"
                    + evidence.factoryFallbackPermalinkResolverOffset
                    + ",\"captionTextCallOffset\":"
                    + evidence.factoryCaptionTextCallOffset
                    + ",\"excerptResolverOffset\":"
                    + evidence.factoryExcerptResolverOffset + ",\"constructorOffset\":"
                    + evidence.factoryConstructorOffset + "},\"request\":{"
                    + "\"sanitizerOffset\":" + evidence.constructorSanitizerOffset
                    + ",\"storeOffset\":" + evidence.constructorStoreOffset
                    + ",\"baseValidityGuardOffset\":"
                    + evidence.validityBaseGuardOffset
                    + ",\"permalinkGuardOffset\":"
                    + evidence.validityPermalinkGuardOffset + "},\"payload\":{"
                    + "\"targetUrlOffset\":" + evidence.payloadTargetUrlOffset
                    + ",\"evidenceValueOffset\":"
                    + evidence.payloadEvidenceValueOffset
                    + ",\"evidenceContainerOffset\":"
                    + evidence.payloadEvidenceContainerOffset + "},\"queueBoundaries\":{"
                    + "\"controllerValidityGuardOffset\":"
                    + evidence.controllerValidityGuardOffset
                    + ",\"clientValidityGuardOffset\":"
                    + evidence.clientValidityGuardOffset + "},\"checks\":{"
                    + "\"permalinkFieldFinal\":true,"
                    + "\"singlePermalinkWrite\":true,"
                    + "\"soleInitializedEvidenceEntry\":true,"
                    + "\"controllerBoundary\":true,"
                    + "\"clientBoundary\":true,"
                    + "\"hostPermalinkResolverFlow\":true,"
                    + "\"shortcodeFirstFallbackFlow\":true,"
                    + "\"hostExcerptResolverFlow\":true,"
                    + "\"factoryViewerGuardAbsent\":true,"
                    + "\"rowViewerGuardAbsent\":true,"
                    + "\"rowDecoratedModifierFlow\":true,"
                    + "\"rowUfiDefaultMaskExact\":true},\"rowControl\":{"
                    + "\"visibilityModifierOffset\":"
                    + evidence.rowVisibilityModifierOffset
                    + ",\"testTagOffset\":" + evidence.rowTestTagOffset
                    + ",\"modifierComposedOffset\":"
                    + evidence.rowModifierComposedOffset
                    + ",\"ufiButtonOffset\":" + evidence.rowUfiButtonOffset
                    + ",\"ufiButtonDefaultMask\":"
                    + evidence.rowUfiButtonDefaultMask + "}}");
        } catch (ContractFailure failure) {
            emitFailure(failure.code);
            System.exit(1);
        } catch (Throwable ignored) {
            emitFailure("inspector_internal_failure");
            System.exit(1);
        }
    }
}
