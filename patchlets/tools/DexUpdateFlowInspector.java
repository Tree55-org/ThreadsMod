import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.base.BaseTryBlock;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.ExceptionHandler;
import com.android.tools.smali.dexlib2.iface.Field;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MethodImplementation;
import com.android.tools.smali.dexlib2.iface.instruction.DualReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.FiveRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.HatLiteralInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.NarrowLiteralInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.OffsetInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.RegisterRangeInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.SwitchPayload;
import com.android.tools.smali.dexlib2.iface.instruction.TwoRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.VariableRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.WideLiteralInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.formats.ArrayPayload;
import com.android.tools.smali.dexlib2.iface.instruction.formats.Instruction23x;
import com.android.tools.smali.dexlib2.iface.instruction.SwitchElement;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.iface.reference.MethodHandleReference;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;
import com.android.tools.smali.dexlib2.iface.reference.TypeReference;
import com.android.tools.smali.dexlib2.iface.value.ArrayEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.BooleanEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.ByteEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.CharEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.DoubleEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.EncodedValue;
import com.android.tools.smali.dexlib2.iface.value.EnumEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.FieldEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.FloatEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.IntEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.LongEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.MethodEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.MethodHandleEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.NullEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.ShortEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.StringEncodedValue;
import com.android.tools.smali.dexlib2.iface.value.TypeEncodedValue;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Binds the complete updater implementation in raw primary DEX to one reviewed
 * generated-D8 semantic graph. The digest covers every updater class, field,
 * method instruction/operand/reference, semantic branch target, register,
 * literal and try/catch exceptional edge. The digest normalizes only reviewed
 * representation differences caused by assembler/layout choices:
 * const-string and goto width forms; code-unit offsets rewritten as semantic
 * instruction indices; and an unreferenced odd-offset payload-alignment NOP
 * after an unconditional terminal. This deliberately fails closed on semantic
 * bytecode drift instead of attempting to bless a new implementation from
 * markers.
 */
public final class DexUpdateFlowInspector {
    private static final String CONTRACT = "threadsmod-update-flow-v1";
    private static final int OPCODE_SETS_REGISTER = 0x10;
    private static final int OPCODE_SETS_WIDE_REGISTER = 0x20;
    private static final String OTHER_ORIGIN = "<other>";

    private static final class Failure extends Exception {
        final String code;
        final String observedHash;
        Failure(String code) { this(code, null); }
        Failure(String code, String observedHash) {
            super(code);
            this.code = code;
            this.observedHash = observedHash;
        }
    }

    private static final class Insn {
        final Instruction instruction;
        final int offset;
        Insn(Instruction instruction, int offset) {
            this.instruction = instruction;
            this.offset = offset;
        }
    }

    private static final class View {
        final ClassDef owner;
        final Method method;
        final MethodImplementation implementation;
        final List<Insn> code = new ArrayList<>();
        final Map<Integer, Integer> indexByOffset = new HashMap<>();
        final int[] parameters;
        final int thisRegister;
        String[][] origins;
        View(ClassDef owner, Method method) throws Failure {
            this.owner = owner;
            this.method = method;
            this.implementation = method.getImplementation();
            require(implementation != null, "method_implementation_missing");
            int offset = 0;
            for (Object object : implementation.getInstructions()) {
                Instruction current = (Instruction) object;
                indexByOffset.put(offset, code.size());
                code.add(new Insn(current, offset));
                offset += current.getCodeUnits();
            }
            require(!code.isEmpty(), "method_code_empty");
            boolean isStatic = (method.getAccessFlags() & 0x8) != 0;
            List<? extends CharSequence> types = method.getParameterTypes();
            parameters = new int[types.size()];
            int parameterWords = 0;
            for (Object type : types) {
                String value = String.valueOf(type);
                parameterWords += value.equals("J") || value.equals("D") ? 2 : 1;
            }
            int next = implementation.getRegisterCount() - parameterWords;
            require(next >= 0, "method_parameter_registers_invalid");
            thisRegister = isStatic ? -1 : next - 1;
            require(isStatic || thisRegister >= 0, "method_this_register_invalid");
            for (int parameter = 0; parameter < types.size(); parameter++) {
                parameters[parameter] = next;
                String value = String.valueOf(types.get(parameter));
                next += value.equals("J") || value.equals("D") ? 2 : 1;
            }
        }
    }

    private static void require(boolean condition, String code) throws Failure {
        if (!condition) throw new Failure(code);
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

    private static String fieldReference(FieldReference field) {
        return field.getDefiningClass() + "->" + field.getName() + ":" + field.getType();
    }

    private static Iterable<Method> methods(ClassDef classDef) {
        List<Method> result = new ArrayList<>();
        for (Object method : classDef.getDirectMethods()) result.add((Method) method);
        for (Object method : classDef.getVirtualMethods()) result.add((Method) method);
        return result;
    }

    private static View exactMethod(Map<String, ClassDef> classes, String owner,
            String name, String descriptor, String code) throws Failure {
        ClassDef classDef = classes.get(owner);
        require(classDef != null, code + "_class");
        Method found = null;
        for (Method method : methods(classDef)) {
            if (!name.equals(method.getName())
                    || !descriptor.equals(methodDescriptor(method))) continue;
            require(found == null, code + "_duplicate");
            found = method;
        }
        require(found != null, code + "_missing");
        return new View(classDef, found);
    }

    private static boolean isInvoke(Instruction instruction) {
        return instruction.getOpcode().name().startsWith("INVOKE_")
                && instruction instanceof ReferenceInstruction
                && ((ReferenceInstruction) instruction).getReference()
                instanceof MethodReference;
    }

    private static String invokeReference(Instruction instruction) {
        if (!isInvoke(instruction)) return null;
        return methodReference((MethodReference)
                ((ReferenceInstruction) instruction).getReference());
    }

    private static int[] invokeRegisters(Instruction instruction) throws Failure {
        require(instruction instanceof VariableRegisterInstruction,
                "invoke_register_shape");
        int count = ((VariableRegisterInstruction) instruction).getRegisterCount();
        if (instruction instanceof RegisterRangeInstruction) {
            int start = ((RegisterRangeInstruction) instruction).getStartRegister();
            int[] result = new int[count];
            for (int index = 0; index < count; index++) result[index] = start + index;
            return result;
        }
        require(instruction instanceof FiveRegisterInstruction && count <= 5,
                "invoke_register_shape");
        FiveRegisterInstruction five = (FiveRegisterInstruction) instruction;
        int[] available = { five.getRegisterC(), five.getRegisterD(),
                five.getRegisterE(), five.getRegisterF(), five.getRegisterG() };
        int[] result = new int[count];
        System.arraycopy(available, 0, result, 0, count);
        return result;
    }

    private static List<Integer> calls(View view, String reference) {
        List<Integer> result = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            if (reference.equals(invokeReference(view.code.get(index).instruction))) {
                result.add(index);
            }
        }
        return result;
    }

    private static int oneCall(View view, String reference, String code) throws Failure {
        List<Integer> found = calls(view, reference);
        require(found.size() == 1, code);
        return found.get(0);
    }

    private static int countCalls(Map<String, ClassDef> classes, String ownerPrefix,
            String reference) throws Failure {
        int count = 0;
        for (ClassDef classDef : classes.values()) {
            if (!classDef.getType().startsWith(ownerPrefix)) continue;
            for (Method method : methods(classDef)) {
                if (method.getImplementation() == null) continue;
                count += calls(new View(classDef, method), reference).size();
            }
        }
        return count;
    }

    private static View soleCaller(Map<String, ClassDef> classes, String ownerPrefix,
            String reference, String code) throws Failure {
        View result = null;
        int count = 0;
        for (ClassDef classDef : classes.values()) {
            if (!classDef.getType().startsWith(ownerPrefix)) continue;
            for (Method method : methods(classDef)) {
                if (method.getImplementation() == null) continue;
                View view = new View(classDef, method);
                int found = calls(view, reference).size();
                count += found;
                if (found > 0) result = view;
            }
        }
        require(count == 1 && result != null, code);
        return result;
    }

    private static int countModCalls(Map<String, ClassDef> classes, String reference)
            throws Failure {
        return countCalls(classes, "Lthreadsmod/", reference)
                + countCalls(classes, "Lcom/threadsmod/", reference);
    }

    private static List<View> modCallers(Map<String, ClassDef> classes,
            String reference) throws Failure {
        List<View> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (ClassDef classDef : classes.values()) {
            if (!classDef.getType().startsWith("Lthreadsmod/")
                    && !classDef.getType().startsWith("Lcom/threadsmod/")) continue;
            for (Method method : methods(classDef)) {
                if (method.getImplementation() == null) continue;
                View view = new View(classDef, method);
                if (!calls(view, reference).isEmpty()
                        && seen.add(methodReference(view))) result.add(view);
            }
        }
        return result;
    }

    private static View soleModStringOwner(Map<String, ClassDef> classes,
            String literal, String code) throws Failure {
        View owner = null;
        int count = 0;
        for (ClassDef classDef : classes.values()) {
            if (!classDef.getType().startsWith("Lthreadsmod/")
                    && !classDef.getType().startsWith("Lcom/threadsmod/")) continue;
            for (Method method : methods(classDef)) {
                if (method.getImplementation() == null) continue;
                View view = new View(classDef, method);
                for (int index = 0; index < view.code.size(); index++) {
                    if (stringIndex(view, literal, index) == index) {
                        count++;
                        owner = view;
                    }
                }
            }
        }
        require(count == 1 && owner != null, code);
        return owner;
    }

    private static View soleModCaller(Map<String, ClassDef> classes, String reference,
            String code) throws Failure {
        View first = null;
        int count = 0;
        for (String prefix : new String[] { "Lthreadsmod/", "Lcom/threadsmod/" }) {
            for (ClassDef classDef : classes.values()) {
                if (!classDef.getType().startsWith(prefix)) continue;
                for (Method method : methods(classDef)) {
                    if (method.getImplementation() == null) continue;
                    View view = new View(classDef, method);
                    int found = calls(view, reference).size();
                    count += found;
                    if (found > 0) first = view;
                }
            }
        }
        require(count == 1 && first != null, code);
        return first;
    }

    private static int fieldIndex(View view, String reference, int start) {
        for (int index = Math.max(0, start); index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!(instruction instanceof ReferenceInstruction)) continue;
            Reference ref = ((ReferenceInstruction) instruction).getReference();
            if (ref instanceof FieldReference
                    && reference.equals(fieldReference((FieldReference) ref))) return index;
        }
        return -1;
    }

    private static int stringIndex(View view, String literal, int start) {
        for (int index = Math.max(0, start); index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!(instruction instanceof ReferenceInstruction)) continue;
            Reference ref = ((ReferenceInstruction) instruction).getReference();
            if (ref instanceof CharSequence && literal.equals(String.valueOf(ref))) return index;
        }
        return -1;
    }

    private static List<Integer> normalSuccessors(View view, int index) throws Failure {
        Instruction instruction = view.code.get(index).instruction;
        String opcode = instruction.getOpcode().name();
        if (opcode.startsWith("RETURN") || opcode.equals("THROW")) {
            return Collections.emptyList();
        }
        require(!opcode.equals("PACKED_SWITCH") && !opcode.equals("SPARSE_SWITCH"),
                "unsupported_switch_control_flow");
        List<Integer> result = new ArrayList<>();
        if (opcode.startsWith("IF_") || opcode.startsWith("GOTO")) {
            require(instruction instanceof OffsetInstruction, "branch_shape");
            int offset = view.code.get(index).offset
                    + ((OffsetInstruction) instruction).getCodeOffset();
            Integer target = view.indexByOffset.get(offset);
            require(target != null, "branch_target_missing");
            result.add(target);
            if (opcode.startsWith("GOTO")) return result;
        }
        if (index + 1 < view.code.size()) result.add(index + 1);
        return result;
    }

    private static List<Integer> exceptionalSuccessors(View view, int index)
            throws Failure {
        List<Integer> result = new ArrayList<>();
        int offset = view.code.get(index).offset;
        for (Object object : view.implementation.getTryBlocks()) {
            require(object instanceof BaseTryBlock, "unsupported_try_block");
            BaseTryBlock block = (BaseTryBlock) object;
            if (offset < block.getStartCodeAddress()
                    || offset >= block.getStartCodeAddress() + block.getCodeUnitCount()) {
                continue;
            }
            for (Object handlerObject : block.getExceptionHandlers()) {
                ExceptionHandler handler = (ExceptionHandler) handlerObject;
                Integer target = view.indexByOffset.get(handler.getHandlerCodeAddress());
                require(target != null, "catch_target_missing");
                if (!result.contains(target)) result.add(target);
            }
        }
        return result;
    }

    private static List<Integer> successors(View view, int index) throws Failure {
        List<Integer> result = new ArrayList<>(normalSuccessors(view, index));
        for (Integer target : exceptionalSuccessors(view, index)) {
            if (!result.contains(target)) result.add(target);
        }
        return result;
    }

    private static boolean canReach(View view, int start, int wanted, int avoided)
            throws Failure {
        if (start < 0 || wanted < 0 || start == avoided) return false;
        List<Integer> pending = new ArrayList<>();
        Set<Integer> seen = new HashSet<>();
        pending.add(start);
        while (!pending.isEmpty()) {
            int index = pending.remove(pending.size() - 1);
            if (index == wanted) return true;
            if (index < 0 || index >= view.code.size() || index == avoided
                    || !seen.add(index)) continue;
            pending.addAll(successors(view, index));
        }
        return false;
    }

    private static boolean dominates(View view, int dominator, int target)
            throws Failure {
        return dominator == target || (canReach(view, 0, target, -1)
                && !canReach(view, 0, target, dominator));
    }

    private static boolean canReachNormal(View view, int start, int wanted,
            int avoided) throws Failure {
        if (start < 0 || wanted < 0 || start == avoided) return false;
        List<Integer> pending = new ArrayList<>();
        Set<Integer> seen = new HashSet<>();
        pending.add(start);
        while (!pending.isEmpty()) {
            int index = pending.remove(pending.size() - 1);
            if (index == wanted) return true;
            if (index < 0 || index >= view.code.size() || index == avoided
                    || !seen.add(index)) continue;
            pending.addAll(normalSuccessors(view, index));
        }
        return false;
    }

    private static boolean dominatesNormal(View view, int dominator, int target)
            throws Failure {
        return dominator == target || (canReachNormal(view, 0, target, -1)
                && !canReachNormal(view, 0, target, dominator));
    }

    private static int moveResultRegister(View view, int call, String code)
            throws Failure {
        require(call + 1 < view.code.size(), code);
        Instruction move = view.code.get(call + 1).instruction;
        require(move instanceof OneRegisterInstruction
                && move.getOpcode().name().startsWith("MOVE_RESULT"), code);
        return ((OneRegisterInstruction) move).getRegisterA();
    }

    private static int consumingBranch(View view, int producer, int window,
            String expectedOpcode, String code)
            throws Failure {
        int register = moveResultRegister(view, producer, code);
        for (int index = producer + 2;
                index < Math.min(view.code.size(), producer + window); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (instruction instanceof OneRegisterInstruction
                    && (instruction.getOpcode().flags & 0x10) != 0
                    && ((OneRegisterInstruction) instruction).getRegisterA() == register) {
                throw new Failure(code);
            }
            if (!expectedOpcode.equals(instruction.getOpcode().name())) continue;
            if (instruction instanceof OneRegisterInstruction
                    && ((OneRegisterInstruction) instruction).getRegisterA() == register) {
                return index;
            }
            if (instruction instanceof TwoRegisterInstruction
                    && (((TwoRegisterInstruction) instruction).getRegisterA() == register
                    || ((TwoRegisterInstruction) instruction).getRegisterB() == register)) {
                return index;
            }
        }
        throw new Failure(code);
    }

    private static void requireGuardedCall(View view, int producer, int guarded,
            String expectedOpcode, String code) throws Failure {
        int branch = consumingBranch(view, producer, 10, expectedOpcode,
                code);
        List<Integer> next = normalSuccessors(view, branch);
        require(next.size() == 2 && dominatesNormal(view, producer, branch)
                && dominatesNormal(view, branch, guarded), code + "_dominance");
        boolean first = canReach(view, next.get(0), guarded, -1);
        boolean second = canReach(view, next.get(1), guarded, -1);
        require(first != second, code + "_bypass");
        for (Integer exceptional : exceptionalSuccessors(view, producer)) {
            require(!canReach(view, exceptional, guarded, -1), code + "_catch_bypass");
        }
        for (int index = producer + 1; index <= branch; index++) {
            for (Integer exceptional : exceptionalSuccessors(view, index)) {
                require(!canReach(view, exceptional, guarded, -1),
                        code + "_intermediate_catch_bypass");
            }
        }
    }

    private static void requireConditionalGuard(View view, int producer, int guarded,
            String expectedOpcode, String code) throws Failure {
        require(canReach(view, 0, producer, -1), code + "_producer_unreachable");
        int branch = consumingBranch(view, producer, 10, expectedOpcode,
                code);
        List<Integer> next = normalSuccessors(view, branch);
        require(next.size() == 2 && canReach(view, producer, branch, -1),
                code + "_branch_shape");
        boolean firstReaches = canReach(view, next.get(0), guarded, -1);
        boolean secondReaches = canReach(view, next.get(1), guarded, -1);
        require(firstReaches != secondReaches, code + "_bypass");
        for (int index = producer; index <= branch; index++) {
            for (Integer exceptional : exceptionalSuccessors(view, index)) {
                require(!canReach(view, exceptional, guarded, -1),
                        code + "_catch_bypass");
            }
        }
    }

    private static int opcodeIndex(View view, String opcode, int start, int end) {
        for (int index = Math.max(0, start);
                index < Math.min(view.code.size(), end); index++) {
            if (opcode.equals(view.code.get(index).instruction.getOpcode().name())) return index;
        }
        return -1;
    }

    private static List<Integer> opcodeIndexes(View view, String prefix) {
        List<Integer> result = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            if (view.code.get(index).instruction.getOpcode().name().startsWith(prefix)) {
                result.add(index);
            }
        }
        return result;
    }

    private static int branchUsingRegister(View view, int register, int start,
            int window, String expectedOpcode, String code) throws Failure {
        for (int index = start; index < Math.min(view.code.size(), start + window); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (instruction instanceof OneRegisterInstruction
                    && (instruction.getOpcode().flags & 0x10) != 0
                    && ((OneRegisterInstruction) instruction).getRegisterA() == register) {
                throw new Failure(code + "_value_clobbered");
            }
            if (!expectedOpcode.equals(instruction.getOpcode().name())) continue;
            if (instruction instanceof OneRegisterInstruction
                    && ((OneRegisterInstruction) instruction).getRegisterA() == register) {
                return index;
            }
            if (instruction instanceof TwoRegisterInstruction
                    && (((TwoRegisterInstruction) instruction).getRegisterA() == register
                    || ((TwoRegisterInstruction) instruction).getRegisterB() == register)) {
                return index;
            }
        }
        throw new Failure(code);
    }

    private static void requireComparisonGuards(View view, int compare, int guarded,
            String expectedOpcode, String code) throws Failure {
        Instruction comparison = view.code.get(compare).instruction;
        require(comparison instanceof OneRegisterInstruction
                && "CMP_LONG".equals(comparison.getOpcode().name()), code + "_comparison");
        int branch = branchUsingRegister(view,
                ((OneRegisterInstruction) comparison).getRegisterA(), compare + 1, 5,
                expectedOpcode, code + "_branch");
        require(dominates(view, compare, guarded)
                && dominates(view, branch, guarded), code + "_dominance");
        List<Integer> next = normalSuccessors(view, branch);
        require(next.size() == 2, code + "_branch_shape");
        require(canReach(view, next.get(0), guarded, -1)
                        != canReach(view, next.get(1), guarded, -1),
                code + "_bypass");
        for (Integer exceptional : exceptionalSuccessors(view, compare)) {
            require(!canReach(view, exceptional, guarded, -1), code + "_catch_bypass");
        }
        for (int index = compare + 1; index <= branch; index++) {
            for (Integer exceptional : exceptionalSuccessors(view, index)) {
                require(!canReach(view, exceptional, guarded, -1),
                        code + "_intermediate_catch_bypass");
            }
        }
    }

    private static int requireComparisonBranch(View view, int compare,
            String expectedOpcode, String code) throws Failure {
        Instruction comparison = view.code.get(compare).instruction;
        require(comparison instanceof OneRegisterInstruction
                && "CMP_LONG".equals(comparison.getOpcode().name())
                && canReach(view, 0, compare, -1), code + "_comparison");
        int branch = branchUsingRegister(view,
                ((OneRegisterInstruction) comparison).getRegisterA(), compare + 1, 5,
                expectedOpcode, code + "_branch");
        require(dominates(view, compare, branch), code + "_dominance");
        for (int index = compare; index <= branch; index++) {
            for (Integer handler : exceptionalSuccessors(view, index)) {
                require(!canReach(view, handler, branch, -1), code + "_catch_reentry");
            }
        }
        return branch;
    }

    private static int comparisonBranchAny(View view, int compare, String code)
            throws Failure {
        Instruction comparison = view.code.get(compare).instruction;
        require(comparison instanceof OneRegisterInstruction
                && "CMP_LONG".equals(comparison.getOpcode().name()), code);
        int register = ((OneRegisterInstruction) comparison).getRegisterA();
        for (int index = compare + 1; index < Math.min(view.code.size(), compare + 6);
                index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (writesRegister(instruction, register)) throw new Failure(code);
            if (instruction.getOpcode().name().startsWith("IF_")
                    && instruction instanceof OneRegisterInstruction
                    && ((OneRegisterInstruction) instruction).getRegisterA() == register) {
                require(canReach(view, 0, compare, -1)
                        && dominates(view, compare, index), code);
                return index;
            }
        }
        throw new Failure(code);
    }

    private static int successfulBooleanConstant(View view, String code) throws Failure {
        int found = -1;
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!(instruction instanceof OneRegisterInstruction)
                    || !(instruction instanceof NarrowLiteralInstruction)
                    || !instruction.getOpcode().name().startsWith("CONST")
                    || ((NarrowLiteralInstruction) instruction).getNarrowLiteral() != 1) {
                continue;
            }
            int register = ((OneRegisterInstruction) instruction).getRegisterA();
            for (int later = index + 1; later < Math.min(view.code.size(), index + 5); later++) {
                Instruction candidate = view.code.get(later).instruction;
                if ("RETURN".equals(candidate.getOpcode().name())
                        && candidate instanceof OneRegisterInstruction
                        && ((OneRegisterInstruction) candidate).getRegisterA() == register) {
                    require(found < 0, code + "_duplicate");
                    found = index;
                    break;
                }
            }
        }
        require(found >= 0, code + "_missing");
        require(canReach(view, 0, found, -1), code + "_unreachable");
        return found;
    }

    private static void requireBranchRejectsBefore(View view, int branch, int success,
            String expectedOpcode, String code) throws Failure {
        Instruction instruction = view.code.get(branch).instruction;
        require(expectedOpcode.equals(instruction.getOpcode().name())
                && canReach(view, 0, branch, -1)
                && dominates(view, branch, success), code + "_opcode");
        List<Integer> next = normalSuccessors(view, branch);
        require(next.size() == 2, code + "_shape");
        require(canReach(view, next.get(0), success, -1)
                        != canReach(view, next.get(1), success, -1), code + "_bypass");
        for (Integer exceptional : exceptionalSuccessors(view, branch)) {
            require(!canReach(view, exceptional, success, -1), code + "_catch_bypass");
        }
    }

    private static String methodReference(View view) {
        return methodReference(view.method);
    }

    private static int countFields(View view, String reference) {
        int count = 0;
        for (Insn insn : view.code) {
            if (!(insn.instruction instanceof ReferenceInstruction)) continue;
            Reference ref = ((ReferenceInstruction) insn.instruction).getReference();
            if (ref instanceof FieldReference
                    && reference.equals(fieldReference((FieldReference) ref))) count++;
        }
        return count;
    }

    private static List<Integer> fieldInstructions(View view, String reference,
            String opcodePrefix) {
        List<Integer> result = new ArrayList<>();
        for (int index = 0; index < view.code.size(); index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!(instruction instanceof ReferenceInstruction)
                    || !instruction.getOpcode().name().startsWith(opcodePrefix)) continue;
            Reference ref = ((ReferenceInstruction) instruction).getReference();
            if (ref instanceof FieldReference
                    && reference.equals(fieldReference((FieldReference) ref))) {
                result.add(index);
            }
        }
        return result;
    }

    private static String staticWriteOrigin(View view, int index, String code)
            throws Failure {
        Instruction instruction = view.code.get(index).instruction;
        require(instruction instanceof OneRegisterInstruction
                && instruction.getOpcode().name().startsWith("SPUT"), code);
        return localOrigin(view, index,
                ((OneRegisterInstruction) instruction).getRegisterA());
    }

    private static void proveBootstrap(Map<String, ClassDef> classes) throws Failure {
        String update = "Lthreadsmod/update/UpdateController;->onResume"
                + "(Landroid/app/Activity;Ljava/lang/Runnable;)V";
        View bootstrap = exactMethod(classes, "Lthreadsmod/bootstrap/ModBootstrap;",
                "onResume", "(Landroid/app/Activity;Ljava/lang/Object;)V",
                "bootstrap_resume");
        int updateCall = oneCall(bootstrap, update, "bootstrap_update_arbitration");
        int[] updateArgs = invokeRegisters(bootstrap.code.get(updateCall).instruction);
        require(updateArgs.length == 2
                && "PARAM:0".equals(localOrigin(bootstrap, updateCall, updateArgs[0])),
                "bootstrap_update_arbitration");
        int fallbackDefinition = oneDefinition(bootstrap, updateCall, updateArgs[1],
                "bootstrap_update_arbitration");
        String fallbackType = newTypeAtDefinition(bootstrap, fallbackDefinition);
        require(fallbackType != null
                && fallbackType.startsWith("Lthreadsmod/bootstrap/ModBootstrap$")
                && fallbackType.endsWith(";"), "bootstrap_update_arbitration");
        // The continuation captures nothing: a no-argument constructor is what proves the
        // activity (or anything else) is not smuggled into the post-arbitration path.
        int fallbackConstructor = oneCall(bootstrap,
                fallbackType + "-><init>()V",
                "bootstrap_update_arbitration");
        int[] constructorArgs = invokeRegisters(
                bootstrap.code.get(fallbackConstructor).instruction);
        require(constructorArgs.length == 1
                && constructorArgs[0] == updateArgs[1], "bootstrap_update_arbitration");
        require(canReach(bootstrap, 0, updateCall, -1), "bootstrap_update_unreachable");
        for (int returnIndex : opcodeIndexes(bootstrap, "RETURN")) {
            require(dominates(bootstrap, updateCall, returnIndex),
                    "bootstrap_update_not_before_return");
        }
        // The continuation does nothing: its run() is exactly one RETURN_VOID. Any
        // instruction at all here is a path that could execute after arbitration.
        View fallbackRun = exactMethod(classes, fallbackType, "run", "()V",
                "bootstrap_fallback_run");
        require(fallbackRun.code.size() == 1
                && "RETURN_VOID".equals(
                        fallbackRun.code.get(0).instruction.getOpcode().name()),
                "bootstrap_fallback_not_empty");
        // The first-run dialog is gone from the build entirely, not merely uncalled.
        require(!classes.containsKey("Lcom/threadsmod/DemoDialog;"),
                "bootstrap_demo_dialog_present");
        require(countModCalls(classes, update) == 3,
                "update_resume_caller_topology");
    }

    private static void proveEligibility(Map<String, ClassDef> classes) throws Failure {
        String controller = "Lthreadsmod/update/UpdateController;";
        String manifest = "Lthreadsmod/update/UpdateManifest;";
        View view = exactMethod(classes, controller, "presentIfApplicable",
                "(Landroid/app/Activity;J" + manifest + ")Z", "present");
        int show = oneCall(view, controller + "->showUpdateDialog"
                + "(Landroid/app/Activity;J" + manifest + "Z)V",
                "eligibility_dialog_call_count");
        int minimumField = fieldIndex(view, manifest + "->minimumModBuild:J", 0);
        int modField = fieldIndex(view, manifest + "->modBuild:J", minimumField + 1);
        int versionField = fieldIndex(view, manifest + "->versionCode:J", modField + 1);
        require(minimumField >= 0 && modField > minimumField
                && versionField > modField && show > versionField,
                "eligibility_field_order");
        int minimumCmp = opcodeIndex(view, "CMP_LONG", minimumField + 1, modField);
        int modCmp = opcodeIndex(view, "CMP_LONG", modField + 1, versionField);
        int versionCmp = opcodeIndex(view, "CMP_LONG", versionField + 1, show);
        require(minimumCmp >= 0, "eligibility_minimum_comparison");
        require(modCmp >= 0, "eligibility_mod_build");
        require(versionCmp >= 0, "eligibility_version_code");
        int modBranch = comparisonBranchAny(view, modCmp, "eligibility_mod_build");
        int versionBranch = comparisonBranchAny(view, versionCmp,
                "eligibility_version_code");
        String modOpcode = viewOpcode(view, modBranch);
        String versionOpcode = viewOpcode(view, versionBranch);
        if ("IF_GTZ".equals(modOpcode)) throw new Failure("eligibility_conjunction");
        require("IF_LEZ".equals(modOpcode), "eligibility_mod_build");
        require("IF_LEZ".equals(versionOpcode), "eligibility_version_code");
        require(modBranch < versionCmp && versionCmp < versionBranch
                && versionBranch < show,
                "eligibility_conjunction");
        requireCmpOrigins(view, minimumCmp, "CONST:1",
                "FIELD:" + manifest + "->minimumModBuild:J",
                "eligibility_minimum");
        requireCmpOrigins(view, modCmp,
                "FIELD:" + manifest + "->modBuild:J", "CONST:1",
                "eligibility_mod_build");
        requireCmpOrigins(view, versionCmp,
                "FIELD:" + manifest + "->versionCode:J",
                "RESULT:Landroid/content/pm/PackageInfo;->getLongVersionCode()J",
                "eligibility_version_code");
        int[] args = invokeRegisters(view.code.get(show).instruction);
        require(args.length == 5, "eligibility_required_argument_shape");
        int requiredRegister = args[4];
        proveRequiredPhi(view, minimumCmp, show, requiredRegister);
        int packageLookup = oneCall(view,
                "Landroid/content/pm/PackageManager;->getPackageInfo("
                + "Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                "package_exception_policy");
        List<Integer> packageHandlers = exceptionalSuccessors(view, packageLookup);
        require(packageHandlers.size() == 1, "package_exception_policy");
        int packageCatch = packageHandlers.get(0);
        int requiredCatchBranch = branchUsingRegister(view, requiredRegister,
                packageCatch, 8, "IF_EQZ", "package_exception_policy");
        List<Integer> unavailableCalls = calls(view, controller
                + "->showUnavailable(Landroid/app/Activity;JLjava/lang/String;)V");
        int unavailable = -1;
        for (Integer candidate : unavailableCalls) {
            if (candidate > packageCatch) unavailable = candidate;
        }
        require(unavailable >= 0, "package_exception_policy");
        List<Integer> catchPaths = normalSuccessors(view, requiredCatchBranch);
        require(catchPaths.size() == 2
                && canReach(view, catchPaths.get(1), unavailable, -1)
                && !canReach(view, catchPaths.get(0), unavailable, -1)
                && !canReach(view, packageCatch, show, -1),
                "package_exception_policy");
    }

    private static void proveRetainedUnavailable(Map<String, ClassDef> classes)
            throws Failure {
        String controller = "Lthreadsmod/update/UpdateController;";
        String accessor = "Lthreadsmod/update/UpdateStore;"
                + "->hasRetainedRequiredForEnforcement(J)Z";
        String unavailable = controller
                + "->showRetainedRequiredUnavailable(Landroid/app/Activity;J)V";
        String unavailableAccessor = controller
                + "->access$800(Landroid/app/Activity;J)V";
        require(countModCalls(classes, accessor) == 3,
                "retained_boolean_call_count");
        int paired = 0;
        for (ClassDef classDef : classes.values()) {
            if (!classDef.getType().startsWith("Lthreadsmod/update/")) continue;
            for (Method method : methods(classDef)) {
                if (method.getImplementation() == null) continue;
                View view = new View(classDef, method);
                List<Integer> reads = calls(view, accessor);
                if (reads.isEmpty()) continue;
                require(reads.size() == 1, "retained_boolean_per_route");
                List<Integer> sinks = calls(view, unavailable);
                sinks.addAll(calls(view, unavailableAccessor));
                if (sinks.size() != 1) {
                    if (controller.equals(view.owner.getType())
                            && "onResume".equals(view.method.getName())) {
                        throw new Failure("retained_on_resume_authority");
                    }
                    if (controller.equals(view.owner.getType())
                            && "handleCheckStartFailure".equals(view.method.getName())) {
                        throw new Failure("retained_start_failure_authority");
                    }
                    throw new Failure("retained_worker_authority");
                }
                int sink = sinks.get(0);
                int retainedBranch = consumingBranch(view, reads.get(0), 12,
                        "IF_EQZ", "retained_boolean_authority");
                int retainedRegister = ((OneRegisterInstruction)
                        view.code.get(retainedBranch).instruction).getRegisterA();
                Set<Integer> retainedDefinitions = reachingDefinitions(view,
                        retainedBranch, retainedRegister,
                        "retained_boolean_authority");
                require(retainedDefinitions.contains(reads.get(0) + 1),
                        "retained_boolean_authority");
                for (Integer definition : retainedDefinitions) {
                    if (definition == reads.get(0) + 1) continue;
                    require(definition >= 0 && "CONST:0".equals(definitionOrigin(
                            view, definition, retainedRegister, new HashSet<String>(),
                            "retained_boolean_authority")),
                            "retained_boolean_authority");
                }
                List<Integer> retainedPaths = normalSuccessors(view, retainedBranch);
                require(retainedPaths.size() == 2
                        && canReach(view, retainedPaths.get(1), sink, -1)
                        && !canReach(view, retainedPaths.get(0), sink, -1),
                        "retained_boolean_authority");
                for (Integer handler : exceptionalSuccessors(view, reads.get(0))) {
                    require(!canReach(view, handler, sink, -1),
                            "retained_boolean_authority");
                }
                require(sink + 1 < view.code.size()
                        && (viewOpcode(view, sink + 1).startsWith("RETURN")
                        || viewOpcode(view, sink + 1).startsWith("GOTO")),
                        "retained_true_route_not_terminal");
                paired++;
            }
        }
        require(paired == 3, "retained_route_count");
        require(countModCalls(classes, unavailable) == 3,
                "retained_route_count");
        View helper = exactMethod(classes, controller,
                "showRetainedRequiredUnavailable", "(Landroid/app/Activity;J)V",
                "retained_helper");
        oneCall(helper, controller + "->showUnavailable"
                + "(Landroid/app/Activity;JLjava/lang/String;)V",
                "retained_unavailable_only");
        for (String forbidden : new String[] {
                controller + "->presentIfApplicable(Landroid/app/Activity;J"
                        + "Lthreadsmod/update/UpdateManifest;)Z",
                controller + "->beginInstall(Landroid/app/Activity;J"
                        + "Lthreadsmod/update/UpdateManifest;Landroid/app/AlertDialog;)V",
                controller + "->obtainVerifiedApk(Landroid/content/Context;"
                        + "Lthreadsmod/update/UpdateManifest;)Ljava/io/File;",
                controller + "->launchInstaller(Landroid/app/Activity;Ljava/io/File;)Z" }) {
            require(calls(helper, forbidden).isEmpty(), "retained_authority_escape");
        }

        View fallbackView = exactMethod(classes, controller, "runFallback",
                "(Landroid/app/Activity;J)V", "required_fallback_guard");
        int requiredField = fieldIndex(fallbackView,
                controller + "->dialogRequired:Z", 0);
        int generationField = fieldIndex(fallbackView,
                controller + "->dialogOwnerGeneration:J", requiredField + 1);
        int dialogField = fieldIndex(fallbackView,
                controller + "->dialog:Landroid/app/AlertDialog;",
                generationField + 1);
        int showing = oneCall(fallbackView,
                "Landroid/app/AlertDialog;->isShowing()Z",
                "required_fallback_guard");
        int fallbackRun = oneCall(fallbackView,
                "Ljava/lang/Runnable;->run()V", "required_fallback_guard");
        require(requiredField >= 0 && generationField > requiredField
                && dialogField > generationField && showing > dialogField
                && fallbackRun > showing, "required_fallback_guard");
        int requiredBranch = opcodeIndex(fallbackView, "IF_EQZ",
                requiredField + 1, generationField);
        int generationComparison = opcodeIndex(fallbackView, "CMP_LONG",
                generationField + 1, dialogField);
        int generationBranch = generationComparison < 0 ? -1
                : opcodeIndex(fallbackView, "IF_NEZ", generationComparison + 1,
                dialogField);
        require(requiredBranch >= 0 && generationComparison >= 0
                && generationBranch >= 0, "required_fallback_guard");
        int showingBranch = consumingBranch(fallbackView, showing, 6, "IF_EQZ",
                "required_fallback_guard");
        List<Integer> showingPaths = normalSuccessors(fallbackView, showingBranch);
        require(showingPaths.size() == 2
                && canReach(fallbackView, showingPaths.get(0), fallbackRun, -1)
                && !canReach(fallbackView, showingPaths.get(1), fallbackRun, -1),
                "required_fallback_guard");
        for (Integer handler : exceptionalSuccessors(fallbackView, showing)) {
            require(!canReach(fallbackView, handler, fallbackRun, -1),
                    "required_fallback_guard");
        }
    }

    private static void proveDialog(Map<String, ClassDef> classes) throws Failure {
        String controller = "Lthreadsmod/update/UpdateController;";
        View view = exactMethod(classes, controller, "showUpdateDialog",
                "(Landroid/app/Activity;JLthreadsmod/update/UpdateManifest;Z)V",
                "dialog");
        int updateText = stringIndex(view, "Update", 0);
        int positive = oneCall(view, "Landroid/app/AlertDialog$Builder;"
                + "->setPositiveButton(Ljava/lang/CharSequence;"
                + "Landroid/content/DialogInterface$OnClickListener;)"
                + "Landroid/app/AlertDialog$Builder;", "dialog_positive_count");
        int laterText = stringIndex(view, "Later", positive + 1);
        int negative = oneCall(view, "Landroid/app/AlertDialog$Builder;"
                + "->setNegativeButton(Ljava/lang/CharSequence;"
                + "Landroid/content/DialogInterface$OnClickListener;)"
                + "Landroid/app/AlertDialog$Builder;", "dialog_later_count");
        int cancelable = oneCall(view,
                "Landroid/app/AlertDialog;->setCancelable(Z)V",
                "dialog_cancelable_count");
        int outside = oneCall(view,
                "Landroid/app/AlertDialog;->setCanceledOnTouchOutside(Z)V",
                "dialog_outside_count");
        int cancelListener = oneCall(view,
                "Landroid/app/AlertDialog;->setOnCancelListener("
                + "Landroid/content/DialogInterface$OnCancelListener;)V",
                "dialog_cancel_listener_count");
        require(updateText >= 0 && positive > updateText && laterText > positive
                && negative > laterText && cancelable > negative && outside > cancelable
                && cancelListener > outside, "optional_later_action");
        int requiredRegister = view.parameters[3];
        int negativeGuard = branchUsingRegister(view, requiredRegister,
                positive + 1, negative - positive + 1, "IF_NEZ",
                "required_action_topology");
        List<Integer> negativePaths = normalSuccessors(view, negativeGuard);
        require(negativePaths.size() == 2
                && dominates(view, negativeGuard, negative)
                && canReach(view, negativePaths.get(1), negative, -1)
                && !canReach(view, negativePaths.get(0), negative, -1),
                "required_action_topology");
        int cancelGuard = branchUsingRegister(view, requiredRegister,
                outside + 1, cancelListener - outside + 1, "IF_NEZ",
                "optional_cancel_persistence");
        List<Integer> cancelPaths = normalSuccessors(view, cancelGuard);
        require(cancelPaths.size() == 2
                && dominates(view, cancelGuard, cancelListener)
                && canReach(view, cancelPaths.get(1), cancelListener, -1)
                && !canReach(view, cancelPaths.get(0), cancelListener, -1),
                "optional_cancel_persistence");
        int[] positiveArgs = invokeRegisters(view.code.get(positive).instruction);
        int[] negativeArgs = invokeRegisters(view.code.get(negative).instruction);
        require(positiveArgs.length == 3
                && "STRING:Update".equals(localOrigin(view, positive, positiveArgs[1])),
                "required_action_topology");
        require(negativeArgs.length == 3
                && "STRING:Later".equals(localOrigin(view, negative, negativeArgs[1]))
                && localOrigin(view, negative, negativeArgs[2]).startsWith(
                "NEW:Lthreadsmod/update/UpdateController$"),
                "optional_later_action");
        int[] cancelableArgs = invokeRegisters(view.code.get(cancelable).instruction);
        require(cancelableArgs.length == 2, "required_cancelability");
        int xor = opcodeIndex(view, "XOR_INT_LIT8", negative + 1, cancelable);
        if (xor < 0) {
            String origin = localOrigin(view, cancelable, cancelableArgs[1]);
            if ("CONST:0".equals(origin)) throw new Failure("optional_cancelability");
            throw new Failure("required_cancelability");
        }
        require(view.code.get(xor).instruction instanceof NarrowLiteralInstruction
                && ((NarrowLiteralInstruction) view.code.get(xor).instruction)
                .getNarrowLiteral() == 1
                && view.code.get(xor).instruction instanceof TwoRegisterInstruction
                && ((TwoRegisterInstruction) view.code.get(xor).instruction)
                .getRegisterB() == requiredRegister,
                "required_cancelability");
        require(reachingDefinitions(view, cancelable, cancelableArgs[1],
                "required_cancelability").equals(
                Collections.singleton(Integer.valueOf(xor))),
                "required_cancelability");
        int[] outsideArgs = invokeRegisters(view.code.get(outside).instruction);
        require(outsideArgs.length == 2, "dialog_outside_argument");
        boolean falseOrigin = false;
        for (int index = cancelable + 1; index < outside; index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (instruction instanceof OneRegisterInstruction
                    && instruction instanceof NarrowLiteralInstruction
                    && ((OneRegisterInstruction) instruction).getRegisterA() == outsideArgs[1]
                    && instruction.getOpcode().name().startsWith("CONST")
                    && ((NarrowLiteralInstruction) instruction).getNarrowLiteral() == 0) {
                falseOrigin = true;
            }
        }
        require(falseOrigin, "optional_cancelability");
        require(countModCalls(classes,
                "Lthreadsmod/update/UpdateStore;->dismiss(Landroid/content/Context;J)Z") == 1,
                "optional_cancel_persistence");

        List<Integer> ownerGenerationWrites = fieldInstructions(view,
                controller + "->dialogOwnerGeneration:J", "SPUT");
        require(ownerGenerationWrites.size() == 1
                && "PARAM:1".equals(staticWriteOrigin(view,
                ownerGenerationWrites.get(0), "dialog_owner_generation_binding")),
                "dialog_owner_generation_binding");

        View unavailable = exactMethod(classes, controller, "showUnavailable",
                "(Landroid/app/Activity;JLjava/lang/String;)V",
                "required_unavailable_cancelability");
        int unavailableCancelable = oneCall(unavailable,
                "Landroid/app/AlertDialog;->setCancelable(Z)V",
                "required_unavailable_cancelability");
        int[] unavailableCancelableArgs = invokeRegisters(
                unavailable.code.get(unavailableCancelable).instruction);
        require(unavailableCancelableArgs.length == 2
                && "CONST:0".equals(localOrigin(unavailable,
                unavailableCancelable, unavailableCancelableArgs[1])),
                "required_unavailable_cancelability");
    }

    private static void proveSignatureAndMetadata(Map<String, ClassDef> classes)
            throws Failure {
        String manifest = "Lthreadsmod/update/UpdateManifest;";
        View parse = exactMethod(classes, manifest, "parseAndVerify",
                "(Ljava/lang/String;JZ)" + manifest, "manifest_parse");
        int verify = oneCall(parse,
                "Lthreadsmod/update/UpdateSignature;"
                + "->verifyProduction(Ljava/lang/String;Ljava/lang/String;)Z",
                "signature_result_guard");
        int construct = oneCall(parse, manifest + "-><init>(JJJLjava/lang/String;JJ"
                + "Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;J"
                + "Ljava/lang/String;Ljava/lang/String;Ljava/util/List;"
                + "Ljava/lang/String;Ljava/lang/String;)V",
                "manifest_construct_count");
        requireGuardedCall(parse, verify, construct, "IF_EQZ",
                "signature_result_guard");
        require(countModCalls(classes,
                "Lthreadsmod/update/UpdateSignature;"
                + "->verifyProduction(Ljava/lang/String;Ljava/lang/String;)Z") == 1,
                "signature_result_guard");
        int algorithmValue = oneCallWithStringArgument(parse,
                manifest + "->requireString(Lorg/json/JSONObject;Ljava/lang/String;I)"
                + "Ljava/lang/String;", "alg", "envelope_algorithm");
        int algorithmEquals = oneEqualsUsing(parse, "STRING:ed25519",
                Integer.valueOf(algorithmValue), "envelope_algorithm");
        requireGuardedCall(parse, algorithmEquals, verify, "IF_EQZ",
                "envelope_algorithm");
        String exactKeys = manifest
                + "->requireExactKeys(Lorg/json/JSONObject;[Ljava/lang/String;)V";
        List<Integer> exactKeyCalls = calls(parse, exactKeys);
        boolean envelopeKeys = false;
        boolean payloadKeys = false;
        String[] envelopeNames = { "payload", "sig", "alg" };
        String[] payloadNames = { "v", "purpose", "packageName", "revision",
                "publishedAt", "modBuild", "minimumModBuild", "versionCode",
                "versionName", "notes", "apkSize", "apkSha256", "signerSha256",
                "downloadUrls" };
        for (Integer call : exactKeyCalls) {
            if (exactKeyArrayAtCall(parse, call, envelopeNames)) envelopeKeys = true;
            if (exactKeyArrayAtCall(parse, call, payloadNames)) payloadKeys = true;
        }
        require(envelopeKeys, "envelope_exact_schema");
        require(payloadKeys, "payload_exact_schema");
        View exactKeyHelper = exactMethod(classes, manifest, "requireExactKeys",
                "(Lorg/json/JSONObject;[Ljava/lang/String;)V",
                "exact_schema_helper_semantics");
        int removeExpected = oneCall(exactKeyHelper,
                "Ljava/util/Set;->remove(Ljava/lang/Object;)Z",
                "exact_schema_helper_semantics");
        consumingBranch(exactKeyHelper, removeExpected, 5, "IF_EQZ",
                "exact_schema_helper_semantics");
        int expectedLength = opcodeIndex(exactKeyHelper, "ARRAY_LENGTH",
                removeExpected + 1, exactKeyHelper.code.size());
        require(expectedLength >= 0, "exact_schema_helper_semantics");
        Instruction expectedLengthInstruction = exactKeyHelper.code.get(
                expectedLength).instruction;
        require(expectedLengthInstruction instanceof TwoRegisterInstruction
                && "PARAM:1".equals(localOrigin(exactKeyHelper, expectedLength,
                ((TwoRegisterInstruction) expectedLengthInstruction).getRegisterB())),
                "exact_schema_helper_semantics");
        int countGuard = opcodeIndex(exactKeyHelper, "IF_NE",
                expectedLength + 1, exactKeyHelper.code.size());
        int remainingEmpty = oneCall(exactKeyHelper,
                "Ljava/util/Set;->isEmpty()Z", "exact_schema_helper_semantics");
        int emptyGuard = consumingBranch(exactKeyHelper, remainingEmpty, 5,
                "IF_EQZ", "exact_schema_helper_semantics");
        int helperReturn = opcodeIndex(exactKeyHelper, "RETURN_VOID",
                emptyGuard + 1, exactKeyHelper.code.size());
        require(countGuard >= 0 && countGuard < remainingEmpty
                && helperReturn > emptyGuard
                && dominatesNormal(exactKeyHelper, countGuard, helperReturn)
                && dominatesNormal(exactKeyHelper, emptyGuard, helperReturn),
                "exact_schema_helper_semantics");

        String requireString = manifest
                + "->requireString(Lorg/json/JSONObject;Ljava/lang/String;I)"
                + "Ljava/lang/String;";
        int purposeValue = oneCallWithStringArgument(parse, requireString,
                "purpose", "payload_purpose");
        int purposeEquals = oneEqualsUsing(parse, "STRING:threadsmod-app-update",
                Integer.valueOf(purposeValue), "payload_purpose");
        requireGuardedCall(parse, purposeEquals, construct, "IF_EQZ",
                "payload_purpose");
        int packageValue = oneCallWithStringArgument(parse, requireString,
                "packageName", "payload_package");
        int packageEquals = oneEqualsUsing(parse, "STRING:app.tree55.threads",
                Integer.valueOf(packageValue), "payload_package");
        requireGuardedCall(parse, packageEquals, construct, "IF_EQZ",
                "payload_package");
        int signerValue = oneCallWithStringArgument(parse, requireString,
                "signerSha256", "metadata_signer_pin");
        int signerEquals = oneEqualsUsing(parse,
                "STRING:317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079",
                Integer.valueOf(signerValue), "metadata_signer_pin");
        requireGuardedCall(parse, signerEquals, construct, "IF_EQZ",
                "metadata_signer_pin");
        int versionCodeValue = oneCallWithStringArgument(parse,
                manifest + "->requirePositiveLong(Lorg/json/JSONObject;"
                + "Ljava/lang/String;)J", "versionCode",
                "manifest_constructor_binding");
        int[] constructArgs = invokeRegisters(parse.code.get(construct).instruction);
        require(constructArgs.length == 22,
                "manifest_constructor_binding");
        require(originatesAtDefinition(parse, construct, constructArgs[10],
                versionCodeValue + 1, new HashSet<String>()),
                "manifest_constructor_binding");
        int publishedValue = oneCallWithStringArgument(parse, requireString,
                "publishedAt", "timestamp_roundtrip");
        int format = oneCall(parse,
                "Ljava/time/format/DateTimeFormatter;->format("
                + "Ljava/time/temporal/TemporalAccessor;)Ljava/lang/String;",
                "timestamp_roundtrip");
        int timestampEquals = -1;
        for (Integer call : calls(parse,
                "Ljava/lang/String;->equals(Ljava/lang/Object;)Z")) {
            int[] arguments = invokeRegisters(parse.code.get(call).instruction);
            if (arguments.length != 2) continue;
            try {
                requireCallResultDefinition(parse, call, arguments[0],
                        publishedValue, "timestamp_roundtrip");
                requireCallResultDefinition(parse, call, arguments[1], format,
                        "timestamp_roundtrip");
                require(timestampEquals < 0, "timestamp_roundtrip");
                timestampEquals = call;
            } catch (Failure ignoredCandidate) {
                // Not the publication timestamp round-trip equality.
            }
        }
        require(timestampEquals >= 0, "timestamp_roundtrip");
        requireGuardedCall(parse, timestampEquals, construct, "IF_EQZ",
                "timestamp_roundtrip");

        String requirePositiveLong = manifest
                + "->requirePositiveLong(Lorg/json/JSONObject;Ljava/lang/String;)J";
        String requireLong = manifest
                + "->requireLong(Lorg/json/JSONObject;Ljava/lang/String;)J";
        int modBuildValue = oneCallWithStringArgument(parse, requirePositiveLong,
                "modBuild", "minimum_mod_build");
        int minimumValue = oneCallWithStringArgument(parse, requireLong,
                "minimumModBuild", "minimum_mod_build");
        int minimumComparison = -1;
        for (Integer comparison : opcodeIndexes(parse, "CMP_LONG")) {
            Instruction23x cmp = (Instruction23x)
                    parse.code.get(comparison).instruction;
            try {
                requireCallResultDefinition(parse, comparison, cmp.getRegisterB(),
                        minimumValue, "minimum_mod_build");
                requireCallResultDefinition(parse, comparison, cmp.getRegisterC(),
                        modBuildValue, "minimum_mod_build");
                minimumComparison = comparison;
            } catch (Failure ignoredCandidate) {
                // Not minimumModBuild > modBuild.
            }
        }
        require(minimumComparison >= 0, "minimum_mod_build");
        int minimumBranch = comparisonBranchAny(parse, minimumComparison,
                "minimum_mod_build");
        require("IF_GTZ".equals(viewOpcode(parse, minimumBranch)),
                "minimum_mod_build");
        require(originatesAtDefinition(parse, construct, constructArgs[5],
                minimumValue + 1, new HashSet<String>()),
                "manifest_constructor_minimum_binding");

        View decodeSignature = exactMethod(classes,
                "Lthreadsmod/update/UpdateSignature;", "decodeCanonicalSignature",
                "(Ljava/lang/String;)[B", "signature_decode");
        int encode = oneCall(decodeSignature,
                "Landroid/util/Base64;->encodeToString([BI)Ljava/lang/String;",
                "signature_base64_canonicality");
        int canonicalEquals = oneEqualsUsing(decodeSignature, "PARAM:0",
                Integer.valueOf(encode), "signature_base64_canonicality");
        int signatureReturn = -1;
        for (int index = 0; index < decodeSignature.code.size(); index++) {
            if ("RETURN_OBJECT".equals(viewOpcode(decodeSignature, index))) {
                String origin = localOrigin(decodeSignature, index,
                        ((OneRegisterInstruction) decodeSignature.code.get(index)
                        .instruction).getRegisterA());
                if (origin != null && origin.startsWith("RESULT:Landroid/util/Base64;"
                        + "->decode")) signatureReturn = index;
            }
        }
        require(signatureReturn >= 0, "signature_base64_canonicality");
        requireGuardedCall(decodeSignature, canonicalEquals, signatureReturn,
                "IF_NEZ", "signature_base64_canonicality");
        View verifyWithKey = exactMethod(classes,
                "Lthreadsmod/update/UpdateSignature;", "verifyWithKey",
                "([B[B[B)Z", "signature_verify_key");
        int scalar = oneCall(verifyWithKey,
                "Lthreadsmod/update/UpdateSignature;->isCanonicalScalar([B)Z",
                "signature_scalar_canonicality");
        int verifyOneShot = oneCall(verifyWithKey,
                "Lnet/i2p/crypto/eddsa/EdDSAEngine;->verifyOneShot([B[B)Z",
                "signature_scalar_canonicality");
        int[] verifyOneShotArgs = invokeRegisters(
                verifyWithKey.code.get(verifyOneShot).instruction);
        require(verifyOneShotArgs.length == 3
                && "PARAM:1".equals(localOrigin(verifyWithKey, verifyOneShot,
                verifyOneShotArgs[1]))
                && "PARAM:2".equals(localOrigin(verifyWithKey, verifyOneShot,
                verifyOneShotArgs[2]))
                && verifyOneShot + 1 < verifyWithKey.code.size()
                && viewOpcode(verifyWithKey, verifyOneShot + 1)
                .startsWith("MOVE_RESULT"),
                "signature_verifier_result_binding");
        requireGuardedCall(verifyWithKey, scalar, verifyOneShot, "IF_NEZ",
                "signature_scalar_canonicality");
        int verifierReturn = -1;
        for (int index = verifyOneShot + 1;
                index < verifyWithKey.code.size(); index++) {
            Instruction instruction = verifyWithKey.code.get(index).instruction;
            if (!"RETURN".equals(instruction.getOpcode().name())
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            if (reachingDefinitions(verifyWithKey, index,
                    ((OneRegisterInstruction) instruction).getRegisterA(),
                    "signature_verifier_result_binding").equals(
                    Collections.singleton(Integer.valueOf(verifyOneShot + 1)))) {
                verifierReturn = index;
            }
        }
        require(verifierReturn >= 0,
                "signature_verifier_result_binding");
        for (Integer handler : exceptionalSuccessors(verifyWithKey,
                verifyOneShot)) {
            require(!canReach(verifyWithKey, handler, verifierReturn, -1),
                    "signature_verifier_result_binding");
        }
        View productionSignature = exactMethod(classes,
                "Lthreadsmod/update/UpdateSignature;", "verifyProduction",
                "(Ljava/lang/String;Ljava/lang/String;)Z",
                "signature_public_key_authority");
        int keyDecode = oneCall(productionSignature,
                "Landroid/util/Base64;->decode(Ljava/lang/String;I)[B",
                "signature_public_key_authority");
        int[] keyDecodeArgs = invokeRegisters(
                productionSignature.code.get(keyDecode).instruction);
        require(keyDecodeArgs.length == 2
                && "STRING:fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk"
                .equals(localOrigin(productionSignature, keyDecode,
                keyDecodeArgs[0]))
                && "CONST:11".equals(localOrigin(productionSignature, keyDecode,
                keyDecodeArgs[1])), "signature_public_key_authority");
        int productionVerify = oneCall(productionSignature,
                "Lthreadsmod/update/UpdateSignature;->verifyWithKey([B[B[B)Z",
                "signature_verifier_result_binding");
        int[] productionVerifyArgs = invokeRegisters(
                productionSignature.code.get(productionVerify).instruction);
        require(productionVerifyArgs.length == 3,
                "signature_verifier_result_binding");
        boolean productionResultReturned = false;
        for (int index = productionVerify + 1;
                index < productionSignature.code.size(); index++) {
            Instruction instruction = productionSignature.code.get(index).instruction;
            if (!"RETURN".equals(instruction.getOpcode().name())
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            if (originatesAtDefinition(productionSignature, index,
                    ((OneRegisterInstruction) instruction).getRegisterA(),
                    productionVerify + 1, new HashSet<String>())) {
                productionResultReturned = true;
            }
        }
        require(productionResultReturned, "signature_verifier_result_binding");
        require(originatesAtDefinition(productionSignature, productionVerify,
                productionVerifyArgs[0], keyDecode + 1, new HashSet<String>()),
                "signature_public_key_authority");

        View fetch = exactMethod(classes, "Lthreadsmod/update/UpdateController;",
                "fetchHighest", "(Landroid/content/Context;)" + manifest,
                "metadata_fetch");
        require(calls(fetch, manifest + "->parseAndVerify(Ljava/lang/String;J)"
                + manifest).size() == 1, "metadata_signed_parse_count");
        int mirror = oneCall(fetch, "Lthreadsmod/update/UpdateEndpoints;"
                + "->metadataMirror(I)Ljava/net/URL;", "metadata_mirror_call_count");
        int parseCall = oneCall(fetch, manifest
                + "->parseAndVerify(Ljava/lang/String;J)" + manifest,
                "metadata_parse_call_count");
        require(mirror < parseCall && dominates(fetch, mirror, parseCall),
                "metadata_parse_before_mirror");
        int add = oneCall(fetch,
                "Ljava/util/List;->add(Ljava/lang/Object;)Z", "metadata_all_mirrors");
        int increment = -1;
        for (int index = add + 1; index < fetch.code.size(); index++) {
            Instruction instruction = fetch.code.get(index).instruction;
            if ("ADD_INT_LIT8".equals(instruction.getOpcode().name())
                    && instruction instanceof NarrowLiteralInstruction
                    && ((NarrowLiteralInstruction) instruction).getNarrowLiteral() == 1) {
                increment = index;
                break;
            }
        }
        require(increment >= 0 && canReach(fetch, add, increment, -1),
                "metadata_all_mirrors");
        List<Integer> iterators = calls(fetch,
                "Ljava/util/List;->iterator()Ljava/util/Iterator;");
        require(iterators.size() == 2 && iterators.get(0) > increment,
                "metadata_highest_revision");
        require(!canReach(fetch, add, iterators.get(0), increment),
                "metadata_all_mirrors");
        for (Integer handler : exceptionalSuccessors(fetch, add)) {
            require(canReach(fetch, handler, increment, -1)
                    && !canReach(fetch, handler, iterators.get(0), increment),
                    "metadata_all_mirrors");
        }

        int highestComparison = -1;
        for (Integer comparison : opcodeIndexes(fetch, "CMP_LONG")) {
            if (comparison > iterators.get(0) && comparison < iterators.get(1)) {
                require(highestComparison < 0, "metadata_highest_revision");
                highestComparison = comparison;
            }
        }
        require(highestComparison >= 0, "metadata_highest_revision");
        int highestBranch = comparisonBranchAny(fetch, highestComparison,
                "metadata_highest_revision");
        require("IF_LEZ".equals(viewOpcode(fetch, highestBranch)),
                "metadata_highest_revision");
        int equivocationComparison = -1;
        for (Integer comparison : opcodeIndexes(fetch, "CMP_LONG")) {
            if (comparison > iterators.get(1)) {
                require(equivocationComparison < 0,
                        "metadata_highest_equivocation");
                equivocationComparison = comparison;
            }
        }
        require(equivocationComparison >= 0,
                "metadata_highest_equivocation");
        int equivocationBranch = comparisonBranchAny(fetch,
                equivocationComparison, "metadata_highest_equivocation");
        require("IF_NEZ".equals(viewOpcode(fetch, equivocationBranch)),
                "metadata_highest_equivocation");
        int releaseEquals = oneCall(fetch, manifest
                + "->sameSignedRelease(" + manifest + ")Z",
                "metadata_highest_equivocation");
        require(releaseEquals > equivocationBranch,
                "metadata_highest_equivocation");
        int equivocationThrow = stringIndex(fetch,
                "update mirrors equivocate at highest revision", releaseEquals);
        require(equivocationThrow > releaseEquals,
                "metadata_highest_equivocation");
        int releaseBranch = consumingBranch(fetch, releaseEquals, 6, "IF_EQZ",
                "metadata_highest_equivocation");
        List<Integer> releasePaths = normalSuccessors(fetch, releaseBranch);
        require(releasePaths.size() == 2
                && releasePaths.get(0) <= equivocationThrow
                && equivocationThrow - releasePaths.get(0) <= 4
                && releasePaths.get(1) == releaseBranch + 1,
                "metadata_highest_equivocation");

        View endpoints = exactMethod(classes, "Lthreadsmod/update/UpdateEndpoints;",
                "<clinit>", "()V", "endpoint_initializer");
        String[] ordered = {
                "https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/"
                        + "published/threadsmod-update.json",
                "https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/"
                        + "threadsmod-update.json",
                "https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/"
                        + "threadsmod-update.json" };
        int array = opcodeIndex(endpoints, "FILLED_NEW_ARRAY", 0,
                endpoints.code.size());
        require(array >= 0, "metadata_endpoint_array");
        int[] endpointRegisters = invokeRegisters(endpoints.code.get(array).instruction);
        require(endpointRegisters.length == 3, "metadata_endpoint_array_shape");
        for (int index = 0; index < ordered.length; index++) {
            require(("STRING:" + ordered[index]).equals(
                    localOrigin(endpoints, array, endpointRegisters[index])),
                    "metadata_mirror_order");
        }
        View redirect = exactMethod(classes, "Lthreadsmod/update/UpdateEndpoints;",
                "validateRedirect", "(Ljava/net/URL;Ljava/lang/String;"
                + "Ljava/lang/String;I)Ljava/net/URL;", "redirect");
        require(calls(redirect, "Lthreadsmod/update/UpdateEndpoints;"
                + "->artifactProvider(Ljava/net/URL;)I").size() == 2,
                "redirect_provider_class");
        List<Integer> providerCalls = calls(redirect,
                "Lthreadsmod/update/UpdateEndpoints;->artifactProvider("
                + "Ljava/net/URL;)I");
        boolean providerGuard = false;
        for (int index = providerCalls.get(1) + 2;
                index < Math.min(redirect.code.size(), providerCalls.get(1) + 12);
                index++) {
            Instruction instruction = redirect.code.get(index).instruction;
            if (!"IF_NE".equals(instruction.getOpcode().name())
                    || !(instruction instanceof TwoRegisterInstruction)) continue;
            TwoRegisterInstruction branch = (TwoRegisterInstruction) instruction;
            try {
                requireCallResultDefinition(redirect, index, branch.getRegisterA(),
                        providerCalls.get(0), "redirect_provider_class");
                requireCallResultDefinition(redirect, index, branch.getRegisterB(),
                        providerCalls.get(1), "redirect_provider_class");
                providerGuard = true;
            } catch (Failure reverse) {
                try {
                    requireCallResultDefinition(redirect, index, branch.getRegisterB(),
                            providerCalls.get(0), "redirect_provider_class");
                    requireCallResultDefinition(redirect, index, branch.getRegisterA(),
                            providerCalls.get(1), "redirect_provider_class");
                    providerGuard = true;
                } catch (Failure ignoredCandidate) {
                    // Not the provider-class equality guard.
                }
            }
        }
        require(providerGuard, "redirect_provider_class");
        boolean hopGuard = false;
        for (int index = 0; index < redirect.code.size(); index++) {
            Instruction instruction = redirect.code.get(index).instruction;
            if (!"IF_GT".equals(instruction.getOpcode().name())
                    || !(instruction instanceof TwoRegisterInstruction)) continue;
            TwoRegisterInstruction branch = (TwoRegisterInstruction) instruction;
            if ("PARAM:3".equals(localOrigin(redirect, index, branch.getRegisterA()))
                    && "CONST:3".equals(localOrigin(redirect, index,
                    branch.getRegisterB()))) hopGuard = true;
        }
        require(hopGuard, "redirect_hop_limit");

        View status = exactMethod(classes, "Lthreadsmod/update/UpdateController;",
                "isAllowedRedirect", "(I)Z", "redirect_status");
        Set<Long> statusConstants = new HashSet<Long>();
        for (Insn insn : status.code) {
            if (insn.instruction instanceof NarrowLiteralInstruction
                    && insn.instruction.getOpcode().name().startsWith("CONST")) {
                long value = ((NarrowLiteralInstruction) insn.instruction)
                        .getNarrowLiteral();
                if (value >= 300L) statusConstants.add(value);
            }
        }
        require(statusConstants.equals(new HashSet<Long>(Arrays.asList(
                301L, 302L, 303L, 307L, 308L))), "redirect_status_allowlist");
        List<Integer> statusBranches = opcodeIndexes(status, "IF_");
        require(statusBranches.size() == 5,
                "redirect_status_allowlist");
        for (int index = 0; index < statusBranches.size(); index++) {
            String expected = index < 4 ? "IF_EQ" : "IF_NE";
            require(expected.equals(viewOpcode(status, statusBranches.get(index))),
                    "redirect_status_allowlist");
        }

        String followRedirects = "Ljavax/net/ssl/HttpsURLConnection;"
                + "->setInstanceFollowRedirects(Z)V";
        List<View> redirectOwners = new ArrayList<>();
        for (Method method : methods(classes.get(
                "Lthreadsmod/update/UpdateController;"))) {
            if (method.getImplementation() == null) continue;
            View owner = new View(classes.get(
                    "Lthreadsmod/update/UpdateController;"), method);
            if (!calls(owner, followRedirects).isEmpty()) redirectOwners.add(owner);
        }
        require(redirectOwners.size() == 2, "automatic_redirects_disabled");
        for (View owner : redirectOwners) {
            int call = oneCall(owner, followRedirects,
                    "automatic_redirects_disabled");
            int[] arguments = invokeRegisters(owner.code.get(call).instruction);
            String redirectFlagOrigin = arguments.length == 2
                    ? localOrigin(owner, call, arguments[1]) : "ARG_COUNT";
            require(arguments.length == 2 && "CONST:0".equals(
                    redirectFlagOrigin), "automatic_redirects_disabled");
        }

        String fetchReference = "Lthreadsmod/update/UpdateController;->fetchHighest("
                + "Landroid/content/Context;)" + manifest;
        View fetchAccessor = soleModCaller(classes, fetchReference,
                "verified_store_result");
        View checkWorker = soleModCaller(classes, methodReference(fetchAccessor),
                "verified_store_result");
        int installVerified = oneCall(checkWorker,
                "Lthreadsmod/update/UpdateStore;->installVerified("
                + "Landroid/content/Context;" + manifest + "J)" + manifest,
                "verified_store_result");
        int installedRegister = moveResultRegister(checkWorker, installVerified,
                "verified_store_result");
        int completionConstructor = -1;
        for (int index = installVerified + 1; index < checkWorker.code.size(); index++) {
            Instruction instruction = checkWorker.code.get(index).instruction;
            if (!isInvoke(instruction)) continue;
            MethodReference reference = (MethodReference)
                    ((ReferenceInstruction) instruction).getReference();
            if ("<init>".equals(reference.getName())
                    && methodDescriptor(reference).equals("("
                    + checkWorker.owner.getType() + "Ljava/lang/Throwable;"
                    + manifest + ")V")) {
                require(completionConstructor < 0, "verified_store_result");
                completionConstructor = index;
            }
        }
        require(completionConstructor >= 0, "verified_store_result");
        int[] completionArgs = invokeRegisters(
                checkWorker.code.get(completionConstructor).instruction);
        require(completionArgs.length == 4, "verified_store_result");
        Set<Integer> completedPolicyDefinitions = reachingDefinitions(checkWorker,
                completionConstructor, completionArgs[3], "verified_store_result");
        require(completedPolicyDefinitions.contains(installVerified + 1)
                && installedRegister == completionArgs[3], "verified_store_result");
        Set<Integer> failureDefinitions = reachingDefinitions(checkWorker,
                completionConstructor, completionArgs[2], "metadata_exception_policy");
        boolean failureFromException = false;
        boolean failureStartsNull = false;
        for (Integer definition : failureDefinitions) {
            if (definition >= 0 && "MOVE_EXCEPTION".equals(
                    viewOpcode(checkWorker, definition))) failureFromException = true;
            if (definition >= 0 && "CONST:0".equals(definitionOrigin(checkWorker,
                    definition, completionArgs[2], new HashSet<String>(),
                    "metadata_exception_policy"))) failureStartsNull = true;
        }
        require(failureFromException && failureStartsNull,
                "metadata_exception_policy");
    }

    private static void proveVerifyFile(Map<String, ClassDef> classes) throws Failure {
        String controller = "Lthreadsmod/update/UpdateController;";
        String manifest = "Lthreadsmod/update/UpdateManifest;";
        View verify = exactMethod(classes, controller, "verifyFile",
                "(Landroid/content/Context;Ljava/io/File;" + manifest + ")Z",
                "verify_file");
        int success = successfulBooleanConstant(verify, "verify_success");
        List<Integer> equals = calls(verify,
                "Ljava/lang/String;->equals(Ljava/lang/Object;)Z");
        if (equals.isEmpty()) throw new Failure("verify_unconditional_success");
        int isFile = oneCall(verify, "Ljava/io/File;->isFile()Z",
                "verify_file_kind");
        int[] isFileArgs = invokeRegisters(verify.code.get(isFile).instruction);
        require(isFileArgs.length == 1
                && "PARAM:1".equals(localOrigin(verify, isFile, isFileArgs[0])),
                "verify_file_kind");
        requireGuardedCall(verify, isFile, success, "IF_EQZ", "verify_file_kind");
        require(countFields(verify, manifest + "->apkSize:J") == 1,
                "verify_size");
        require(countFields(verify, manifest + "->apkSha256:Ljava/lang/String;") == 1,
                "verify_hash");
        require(countFields(verify, manifest + "->versionCode:J") == 1,
                "verify_version_code");
        require(countFields(verify, manifest + "->versionName:Ljava/lang/String;") == 1,
                "verify_version_name");
        require(countFields(verify,
                "Landroid/content/pm/PackageInfo;->packageName:Ljava/lang/String;") == 1,
                "verify_package");
        require(countFields(verify,
                "Landroid/content/pm/PackageInfo;->versionName:Ljava/lang/String;") == 1,
                "verify_version_name");
        List<Integer> comparisons = opcodeIndexes(verify, "CMP_LONG");
        if (comparisons.size() < 3) {
            if (countFields(verify, manifest + "->apkSize:J") == 0)
                throw new Failure("verify_size");
            if (countFields(verify, manifest + "->versionCode:J") == 0)
                throw new Failure("verify_version_code");
            throw new Failure("verify_newer_version");
        }
        require(comparisons.size() == 3, "verify_newer_version");
        requireComparisonGuards(verify, comparisons.get(0), success, "IF_NEZ",
                "verify_size");
        requireComparisonGuards(verify, comparisons.get(1), success, "IF_NEZ",
                "verify_version_code");
        requireComparisonGuards(verify, comparisons.get(2), success, "IF_GTZ",
                "verify_newer_version");
        requireCmpOrigins(verify, comparisons.get(0),
                "RESULT:Ljava/io/File;->length()J",
                "FIELD:" + manifest + "->apkSize:J", "verify_size");
        requireCmpOrigins(verify, comparisons.get(1),
                "RESULT:Landroid/content/pm/PackageInfo;->getLongVersionCode()J",
                "FIELD:" + manifest + "->versionCode:J", "verify_version_code");
        requireCmpOrigins(verify, comparisons.get(2),
                "RESULT:Landroid/content/pm/PackageInfo;->getLongVersionCode()J",
                "RESULT:Landroid/content/pm/PackageInfo;->getLongVersionCode()J",
                "verify_newer_version");
        int archive = oneCall(verify,
                "Landroid/content/pm/PackageManager;->getPackageArchiveInfo("
                + "Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                "verify_archive_lookup_count");
        int current = oneCall(verify,
                "Landroid/content/pm/PackageManager;->getPackageInfo("
                + "Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                "verify_current_lookup_count");
        require(archive < current && current < success,
                "verify_package_lookup_order");
        int sha = oneCall(verify, controller
                + "->sha256(Ljava/io/File;)Ljava/lang/String;", "verify_hash");
        int[] shaArgs = invokeRegisters(verify.code.get(sha).instruction);
        require(shaArgs.length == 1
                && "PARAM:1".equals(localOrigin(verify, sha, shaArgs[0])),
                "verify_hash");
        List<Integer> hashEquals = equalsCallsWithFieldReceiver(verify,
                manifest + "->apkSha256:Ljava/lang/String;", "PARAM:2");
        require(hashEquals.size() == 1, "verify_hash");
        int[] hashArgs = invokeRegisters(
                verify.code.get(hashEquals.get(0)).instruction);
        requireCallResultDefinition(verify, hashEquals.get(0), hashArgs[1], sha,
                "verify_hash");
        requireGuardedCall(verify, hashEquals.get(0), success, "IF_NEZ",
                "verify_hash");

        int archiveRegister = moveResultRegister(verify, archive,
                "verify_archive_result");
        int archiveNull = branchUsingRegister(verify, archiveRegister, archive + 2,
                16, "IF_EQZ", "verify_archive_presence");
        requireBranchRejectsBefore(verify, archiveNull, success, "IF_EQZ",
                "verify_archive_presence");

        int packageEquals = oneEqualsUsing(verify,
                "STRING:app.tree55.threads", null, "verify_package");
        int[] packageArgs = invokeRegisters(
                verify.code.get(packageEquals).instruction);
        requireFieldDefinition(verify, packageEquals, packageArgs[1],
                "Landroid/content/pm/PackageInfo;->packageName:Ljava/lang/String;",
                "RESULT:Landroid/content/pm/PackageManager;->getPackageArchiveInfo("
                + "Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                "verify_package");
        requireGuardedCall(verify, packageEquals, success, "IF_EQZ",
                "verify_package");

        List<Integer> nameEquals = equalsCallsWithFieldReceiver(verify,
                manifest + "->versionName:Ljava/lang/String;", "PARAM:2");
        require(nameEquals.size() == 1, "verify_version_name");
        int[] nameArgs = invokeRegisters(verify.code.get(nameEquals.get(0)).instruction);
        requireFieldDefinition(verify, nameEquals.get(0), nameArgs[1],
                "Landroid/content/pm/PackageInfo;->versionName:Ljava/lang/String;",
                "RESULT:Landroid/content/pm/PackageManager;->getPackageArchiveInfo("
                + "Ljava/lang/String;I)Landroid/content/pm/PackageInfo;",
                "verify_version_name");
        requireGuardedCall(verify, nameEquals.get(0), success, "IF_EQZ",
                "verify_version_name");

        List<Integer> signerCalls = calls(verify, controller
                + "->onlySignerSha256(Landroid/content/pm/PackageInfo;)Ljava/lang/String;");
        require(signerCalls.size() == 2, "verify_single_signer");
        int[] archiveSignerArgs = invokeRegisters(
                verify.code.get(signerCalls.get(0)).instruction);
        int[] currentSignerArgs = invokeRegisters(
                verify.code.get(signerCalls.get(1)).instruction);
        require(archiveSignerArgs.length == 1 && currentSignerArgs.length == 1,
                "verify_single_signer");
        requireCallResultDefinition(verify, signerCalls.get(0), archiveSignerArgs[0],
                archive, "verify_archive_signer");
        requireCallResultDefinition(verify, signerCalls.get(1), currentSignerArgs[0],
                current, "verify_current_signer");
        List<Integer> signerEqualsCalls = equalsCallsWithFieldReceiver(verify,
                manifest + "->signerSha256:Ljava/lang/String;", "PARAM:2");
        int pinEquals = -1;
        int archiveEquals = -1;
        int currentEquals = -1;
        for (Integer call : signerEqualsCalls) {
            int[] arguments = invokeRegisters(verify.code.get(call).instruction);
            String origin = localOrigin(verify, call, arguments[1]);
            if (("STRING:317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079")
                    .equals(origin)) pinEquals = call;
            try {
                requireCallResultDefinition(verify, call, arguments[1],
                        signerCalls.get(0), "verify_archive_signer");
                archiveEquals = call;
            } catch (Failure ignored) { }
            try {
                requireCallResultDefinition(verify, call, arguments[1],
                        signerCalls.get(1), "verify_current_signer");
                currentEquals = call;
            } catch (Failure ignored) { }
        }
        if (signerEqualsCalls.isEmpty()) {
            throw new Failure("verify_unconditional_success");
        }
        require(pinEquals >= 0, "verify_signer_pin");
        require(archiveEquals >= 0, "verify_archive_signer");
        require(currentEquals >= 0, "verify_current_signer");
        require(signerEqualsCalls.size() == 3
                && countFields(verify,
                manifest + "->signerSha256:Ljava/lang/String;") == 3,
                "verify_current_signer");
        requireGuardedCall(verify, pinEquals, success, "IF_EQZ", "verify_signer_pin");
        requireGuardedCall(verify, archiveEquals, success, "IF_EQZ",
                "verify_archive_signer");
        requireGuardedCall(verify, currentEquals, success, "IF_EQZ",
                "verify_current_signer");

        View signer = exactMethod(classes, controller, "onlySignerSha256",
                "(Landroid/content/pm/PackageInfo;)Ljava/lang/String;", "signer");
        int signers = oneCall(signer,
                "Landroid/content/pm/SigningInfo;->getApkContentsSigners()"
                + "[Landroid/content/pm/Signature;", "signer_array_call_count");
        int digest = oneCall(signer,
                "Ljava/security/MessageDigest;->digest([B)[B", "signer_digest_count");
        require(signers < digest && dominates(signer, signers, digest),
                "signer_array_before_digest");
        int signerArrayLength = -1;
        for (int index = signers + 2; index < digest; index++) {
            Instruction instruction = signer.code.get(index).instruction;
            if (!"ARRAY_LENGTH".equals(instruction.getOpcode().name())
                    || !(instruction instanceof TwoRegisterInstruction)) continue;
            TwoRegisterInstruction length = (TwoRegisterInstruction) instruction;
            try {
                requireCallResultDefinition(signer, index, length.getRegisterB(),
                        signers, "verify_single_signer");
                require(signerArrayLength < 0, "verify_single_signer");
                signerArrayLength = index;
            } catch (Failure ignoredCandidate) {
                // Not the length of getApkContentsSigners().
            }
        }
        require(signerArrayLength >= 0, "verify_single_signer");
        Instruction lengthInstruction = signer.code.get(signerArrayLength).instruction;
        int lengthRegister = ((TwoRegisterInstruction) lengthInstruction).getRegisterA();
        int cardinalityBranch = -1;
        for (int index = signerArrayLength + 1;
                index < Math.min(digest, signerArrayLength + 8); index++) {
            Instruction instruction = signer.code.get(index).instruction;
            if (!"IF_EQ".equals(instruction.getOpcode().name())
                    || !(instruction instanceof TwoRegisterInstruction)) continue;
            TwoRegisterInstruction branch = (TwoRegisterInstruction) instruction;
            int other = -1;
            if (branch.getRegisterA() == lengthRegister) other = branch.getRegisterB();
            if (branch.getRegisterB() == lengthRegister) other = branch.getRegisterA();
            if (other >= 0 && "CONST:1".equals(localOrigin(signer, index, other))) {
                cardinalityBranch = index;
            }
        }
        require(cardinalityBranch >= 0 && dominatesNormal(signer,
                signerArrayLength, cardinalityBranch)
                && dominatesNormal(signer, cardinalityBranch, digest),
                "verify_single_signer");
        List<Integer> cardinalityPaths = normalSuccessors(signer,
                cardinalityBranch);
        require(cardinalityPaths.size() == 2
                && canReach(signer, cardinalityPaths.get(0), digest, -1)
                != canReach(signer, cardinalityPaths.get(1), digest, -1),
                "verify_single_signer");
        List<Integer> signerIfs = opcodeIndexes(signer, "IF_");
        require(signerIfs.size() == 4, "verify_single_signer");
        String[] signerOpcodes = { "IF_EQZ", "IF_NEZ", "IF_EQZ", "IF_EQ" };
        for (int index = 0; index < signerIfs.size(); index++) {
            requireBranchRejectsBefore(signer, signerIfs.get(index), digest,
                    signerOpcodes[index], index == 2
                    ? "verify_single_signer" : "verify_single_signer");
        }
    }

    private static void proveDownloadAndInstaller(Map<String, ClassDef> classes)
            throws Failure {
        String controller = "Lthreadsmod/update/UpdateController;";
        String manifest = "Lthreadsmod/update/UpdateManifest;";
        String begin = controller + "->beginInstall(Landroid/app/Activity;J"
                + manifest + "Landroid/app/AlertDialog;)V";
        View beginAccessor = soleModCaller(classes, begin, "explicit_update_tap");
        require(beginAccessor.owner.getType().equals(controller)
                && beginAccessor.method.getName().startsWith("access$"),
                "begin_install_accessor");
        View click = soleModCaller(classes, methodReference(beginAccessor),
                "begin_install_tap_caller_count");
        require("onClick".equals(click.method.getName())
                && "(Landroid/view/View;)V".equals(methodDescriptor(click.method))
                && click.owner.getInterfaces().contains("Landroid/view/View$OnClickListener;"),
                "download_without_explicit_tap");

        View beginMethod = exactMethod(classes, controller, "beginInstall",
                "(Landroid/app/Activity;J" + manifest
                + "Landroid/app/AlertDialog;)V", "begin_install");
        List<Integer> beginOwnerCalls = calls(beginMethod, controller
                + "->isCurrentOwner(Landroid/app/Activity;J)Z");
        require(beginOwnerCalls.size() == 2, "begin_owner");
        int beginOwner = beginOwnerCalls.get(0);
        int beginAuthority = oneCall(beginMethod,
                "Landroid/app/Activity;->getPackageManager()"
                + "Landroid/content/pm/PackageManager;", "begin_package_manager");
        int beginOwnerRegister = moveResultRegister(beginMethod, beginOwner,
                "begin_owner");
        int beginOwnerGuard = opcodeIndex(beginMethod, "IF_NEZ",
                beginOwner + 1, beginOwner + 6);
        require(beginOwnerGuard >= 0, "begin_owner_guard_missing");
        require(beginMethod.code.get(beginOwnerGuard).instruction
                instanceof OneRegisterInstruction, "begin_owner_guard_shape");
        require(((OneRegisterInstruction) beginMethod.code.get(beginOwnerGuard)
                .instruction).getRegisterA() == beginOwnerRegister,
                "begin_owner_guard_register");
        require(beginOwnerGuard < beginAuthority, "begin_owner_guard_order");
        List<Integer> beginPaths = normalSuccessors(beginMethod, beginOwnerGuard);
        require(beginPaths.size() == 2
                && canReach(beginMethod, beginPaths.get(0), beginAuthority, -1)
                != canReach(beginMethod, beginPaths.get(1), beginAuthority, -1),
                "begin_owner_paths");

        String obtain = controller + "->obtainVerifiedApk(Landroid/content/Context;"
                + manifest + ")Ljava/io/File;";
        View obtainAccessor = soleModCaller(classes, obtain,
                "verified_file_provenance");
        View downloadWorker = soleModCaller(classes, methodReference(obtainAccessor),
                "verified_file_provenance");
        int obtainCall = oneCall(downloadWorker, methodReference(obtainAccessor),
                "verified_file_provenance");
        int postConstructor = -1;
        for (int index = 0; index < downloadWorker.code.size(); index++) {
            Instruction instruction = downloadWorker.code.get(index).instruction;
            if (!isInvoke(instruction)) continue;
            MethodReference reference = (MethodReference)
                    ((ReferenceInstruction) instruction).getReference();
            if ("<init>".equals(reference.getName())
                    && methodDescriptor(reference).equals("("
                    + downloadWorker.owner.getType() + "Ljava/io/File;)V")
                    && reference.getDefiningClass().startsWith(
                    downloadWorker.owner.getType().substring(0,
                    downloadWorker.owner.getType().length() - 1) + "$")) {
                require(postConstructor < 0, "verified_file_provenance");
                postConstructor = index;
            }
        }
        require(postConstructor >= 0, "verified_file_provenance");
        int[] postArgs = invokeRegisters(
                downloadWorker.code.get(postConstructor).instruction);
        require(postArgs.length == 3, "verified_file_provenance");
        Set<Integer> completedDefinitions = reachingDefinitions(downloadWorker,
                postConstructor, postArgs[2], "verified_file_provenance");
        boolean fromVerifiedObtain = false;
        boolean exceptionIsNull = false;
        for (Integer definition : completedDefinitions) {
            if (definition == obtainCall + 1
                    && viewOpcode(downloadWorker, definition)
                    .startsWith("MOVE_RESULT")) fromVerifiedObtain = true;
            if (definition >= 0
                    && "CONST:0".equals(definitionOrigin(downloadWorker, definition,
                    postArgs[2], new HashSet<String>(),
                    "download_exception_file"))) exceptionIsNull = true;
        }
        require(fromVerifiedObtain, "verified_file_provenance");
        require(exceptionIsNull && completedDefinitions.size() == 2,
                "download_exception_file");

        View obtainMethod = exactMethod(classes, controller, "obtainVerifiedApk",
                "(Landroid/content/Context;" + manifest + ")Ljava/io/File;",
                "obtain_verified_apk");
        int completedNew = -1;
        List<Integer> fileConstructors = calls(obtainMethod,
                "Ljava/io/File;-><init>(Ljava/io/File;Ljava/lang/String;)V");
        for (Integer constructor : fileConstructors) {
            int[] arguments = invokeRegisters(
                    obtainMethod.code.get(constructor).instruction);
            if (arguments.length != 3
                    || !"STRING:threadsmod-update.apk".equals(
                    localOrigin(obtainMethod, constructor, arguments[2]))) continue;
            completedNew = oneDefinition(obtainMethod, constructor, arguments[0],
                    "mirror_exception_file");
        }
        require(completedNew >= 0
                && "Ljava/io/File;".equals(newTypeAtDefinition(
                obtainMethod, completedNew)), "mirror_exception_file");
        String completedOrigin = "NEW:Ljava/io/File;#" + completedNew;
        int objectReturns = 0;
        List<Integer> completedReturns = new ArrayList<>();
        for (int index = 0; index < obtainMethod.code.size(); index++) {
            Instruction instruction = obtainMethod.code.get(index).instruction;
            if (!"RETURN_OBJECT".equals(instruction.getOpcode().name())
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            objectReturns++;
            completedReturns.add(index);
            require(completedOrigin.equals(localOrigin(obtainMethod, index,
                    ((OneRegisterInstruction) instruction).getRegisterA())),
                    "mirror_exception_file");
        }
        require(objectReturns == 2, "mirror_exception_file");
        String verifyReference = controller + "->verifyFile("
                + "Landroid/content/Context;Ljava/io/File;" + manifest + ")Z";
        List<Integer> obtainVerifications = calls(obtainMethod, verifyReference);
        require(obtainVerifications.size() == 2,
                "cached_verified_file_guard");
        int cachedGuard = consumingBranch(obtainMethod,
                obtainVerifications.get(0), 24, "IF_EQZ",
                "cached_verified_file_guard");
        List<Integer> cachedPaths = normalSuccessors(obtainMethod, cachedGuard);
        require(cachedPaths.size() == 2
                && cachedGuard + 1 == completedReturns.get(0)
                && cachedPaths.contains(Integer.valueOf(cachedGuard + 1))
                && Collections.max(cachedPaths) > completedReturns.get(0),
                "cached_verified_file_guard");
        int rename = oneCall(obtainMethod,
                "Ljava/io/File;->renameTo(Ljava/io/File;)Z",
                "download_rename_guard");
        int downloadedVerifyGuard = consumingBranch(obtainMethod,
                obtainVerifications.get(1), 8, "IF_EQZ",
                "download_rename_guard");
        List<Integer> downloadedVerifyPaths = normalSuccessors(obtainMethod,
                downloadedVerifyGuard);
        require(downloadedVerifyPaths.size() == 2
                && downloadedVerifyPaths.contains(
                Integer.valueOf(downloadedVerifyGuard + 1))
                && downloadedVerifyGuard + 1 < rename
                && Collections.max(downloadedVerifyPaths) > completedReturns.get(1),
                "download_rename_guard");
        int renameGuard = consumingBranch(obtainMethod, rename, 6, "IF_EQZ",
                "download_rename_guard");
        List<Integer> renamePaths = normalSuccessors(obtainMethod, renameGuard);
        require(renamePaths.size() == 2
                && renameGuard + 1 == completedReturns.get(1)
                && renamePaths.contains(Integer.valueOf(renameGuard + 1))
                && Collections.max(renamePaths) > completedReturns.get(1),
                "download_rename_guard");
        int[] renameArgs = invokeRegisters(
                obtainMethod.code.get(rename).instruction);
        require(renameArgs.length == 2
                && completedOrigin.equals(localOrigin(obtainMethod, rename,
                renameArgs[1])), "download_rename_guard");

        View finish = exactMethod(classes, controller, "finishDownload",
                "(J" + manifest + "Ljava/io/File;)V", "finish_download");
        int owner = oneCall(finish, controller
                + "->isCurrentOwner(Landroid/app/Activity;J)Z",
                "finish_owner");
        int showing = oneCall(finish,
                "Landroid/app/AlertDialog;->isShowing()Z", "current_dialog_showing");
        int currentBinary = oneCall(finish,
                "Lthreadsmod/update/UpdateStore;->runIfCurrentBinary("
                + "Landroid/content/Context;J" + manifest
                + "Lthreadsmod/update/UpdateStore$CurrentBinaryAction;)I",
                "current_binary_revalidation");
        require(owner < showing && showing < currentBinary,
                "finish_authority_order");
        requireGuardedCall(finish, owner, currentBinary, "IF_EQZ",
                "finish_owner");
        requireGuardedCall(finish, showing, currentBinary, "IF_NEZ",
                "finish_dialog_showing");
        for (Integer exceptional : exceptionalSuccessors(finish, currentBinary)) {
            require(!canReach(finish, exceptional, currentBinary, -1),
                    "finish_policy_catch_installer_bypass");
        }

        View runCurrent = exactMethod(classes, "Lthreadsmod/update/UpdateStore;",
                "runIfCurrentBinary", "(Landroid/content/Context;J" + manifest
                + "Lthreadsmod/update/UpdateStore$CurrentBinaryAction;)I",
                "current_binary");
        require((runCurrent.method.getAccessFlags() & 0x20000) != 0,
                "current_binary_monitor");
        int sameBinary = oneCall(runCurrent, manifest + "->sameBinary(" + manifest
                + ")Z", "current_binary_same_call_count");
        int action = oneCall(runCurrent,
                "Lthreadsmod/update/UpdateStore$CurrentBinaryAction;->run()Z",
                "current_binary_action_count");
        int loadCurrent = oneCall(runCurrent,
                "Lthreadsmod/update/UpdateStore;->load(Landroid/content/Context;J)"
                + manifest, "current_binary_revalidation");
        int[] sameBinaryArgs = invokeRegisters(
                runCurrent.code.get(sameBinary).instruction);
        require(sameBinaryArgs.length == 2,
                "current_binary_revalidation");
        requireCallResultDefinition(runCurrent, sameBinary,
                sameBinaryArgs[0], loadCurrent, "current_binary_revalidation");
        require("PARAM:2".equals(localOrigin(runCurrent, sameBinary,
                sameBinaryArgs[1])), "current_binary_revalidation");
        int[] actionArgs = invokeRegisters(runCurrent.code.get(action).instruction);
        require(actionArgs.length == 1 && "PARAM:3".equals(localOrigin(
                runCurrent, action, actionArgs[0])), "current_policy_exception");
        requireGuardedCall(runCurrent, sameBinary, action, "IF_NEZ",
                "current_binary_guard");
        String actionReference = "Lthreadsmod/update/UpdateStore$CurrentBinaryAction;"
                + "->run()Z";
        require(countModCalls(classes, actionReference) == 1
                && methodReference(soleModCaller(classes, actionReference,
                "current_policy_exception")).equals(methodReference(runCurrent)),
                "current_policy_exception");

        String launch = controller
                + "->launchInstaller(Landroid/app/Activity;Ljava/io/File;)Z";
        View launchAccessor = soleModCaller(classes, launch,
                "current_policy_exception");
        View actionCaller = soleModCaller(classes, methodReference(launchAccessor),
                "installer_action_caller_count");
        require("run".equals(actionCaller.method.getName())
                && "()Z".equals(methodDescriptor(actionCaller.method))
                && actionCaller.owner.getInterfaces().contains(
                "Lthreadsmod/update/UpdateStore$CurrentBinaryAction;"),
                "installer_outside_current_binary_action");
        int actionLaunch = oneCall(actionCaller, methodReference(launchAccessor),
                "installer_file_provenance");
        int[] actionLaunchArgs = invokeRegisters(
                actionCaller.code.get(actionLaunch).instruction);
        require(actionLaunchArgs.length == 2
                && localOrigin(actionCaller, actionLaunch,
                actionLaunchArgs[0]).startsWith("FIELD:")
                && localOrigin(actionCaller, actionLaunch,
                actionLaunchArgs[0]).contains("val$installerActivity")
                && localOrigin(actionCaller, actionLaunch,
                actionLaunchArgs[1]).startsWith("FIELD:")
                && localOrigin(actionCaller, actionLaunch,
                actionLaunchArgs[1]).contains("val$completed"),
                "installer_file_provenance");
        int launchFromAccessor = oneCall(launchAccessor, launch,
                "installer_file_provenance");
        int[] launchFromAccessorArgs = invokeRegisters(
                launchAccessor.code.get(launchFromAccessor).instruction);
        require(launchFromAccessorArgs.length == 2
                && "PARAM:0".equals(localOrigin(launchAccessor,
                launchFromAccessor, launchFromAccessorArgs[0]))
                && "PARAM:1".equals(localOrigin(launchAccessor,
                launchFromAccessor, launchFromAccessorArgs[1])),
                "installer_file_provenance");
        View launchMethod = exactMethod(classes, controller, "launchInstaller",
                "(Landroid/app/Activity;Ljava/io/File;)Z", "installer");
        String provider = "Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;"
                + "[Ljava/lang/Object;)Ljava/lang/Object;";
        oneCall(launchMethod, provider, "installer_fileprovider_invoke_count");
        require(stringIndex(launchMethod,
                "androidx.core.content.FileProvider", 0) >= 0
                && stringIndex(launchMethod,
                "app.tree55.threads.fileprovider", 0) >= 0
                && stringIndex(launchMethod,
                "application/vnd.android.package-archive", 0) >= 0,
                "installer_exact_binding");
        String setData = "Landroid/content/Intent;->setDataAndType(Landroid/net/Uri;"
                + "Ljava/lang/String;)Landroid/content/Intent;";
        require(countModCalls(classes, setData) == 1
                && methodReference(soleModCaller(classes, setData,
                "installer_mime_global_caller_count")).equals(
                methodReference(launchMethod)), "installer_mime_global_owner");
        require(methodReference(soleModStringOwner(classes,
                "androidx.core.content.FileProvider",
                "installer_fileprovider_global_caller_count"))
                .equals(methodReference(launchMethod)),
                "installer_fileprovider_global_owner");
        int startActivity = oneCall(launchMethod,
                "Landroid/app/Activity;->startActivity(Landroid/content/Intent;)V",
                "installer_exception_success");
        int trueReturns = 0;
        int falseReturns = 0;
        for (int index = 0; index < launchMethod.code.size(); index++) {
            Instruction instruction = launchMethod.code.get(index).instruction;
            if (!"RETURN".equals(instruction.getOpcode().name())
                    || !(instruction instanceof OneRegisterInstruction)) continue;
            String origin = localOrigin(launchMethod, index,
                    ((OneRegisterInstruction) instruction).getRegisterA());
            if ("CONST:1".equals(origin)) {
                trueReturns++;
                require(dominates(launchMethod, startActivity, index),
                        "installer_exception_success");
            } else if ("CONST:0".equals(origin)) {
                falseReturns++;
            } else {
                throw new Failure("installer_exception_success");
            }
        }
        require(trueReturns == 1 && falseReturns == 1,
                "installer_exception_success");
        for (Integer handler : exceptionalSuccessors(launchMethod, startActivity)) {
            for (int index = 0; index < launchMethod.code.size(); index++) {
                Instruction instruction = launchMethod.code.get(index).instruction;
                if ("RETURN".equals(instruction.getOpcode().name())
                        && instruction instanceof OneRegisterInstruction
                        && "CONST:1".equals(localOrigin(launchMethod, index,
                        ((OneRegisterInstruction) instruction).getRegisterA()))) {
                    require(!canReach(launchMethod, handler, index, -1),
                            "installer_exception_success");
                }
            }
        }

        View currentOwner = exactMethod(classes, controller, "isCurrentOwner",
                "(Landroid/app/Activity;J)Z", "lifecycle_owner_conjunction");
        int ownerGet = oneCall(currentOwner,
                "Ljava/lang/ref/WeakReference;->get()Ljava/lang/Object;",
                "lifecycle_owner_conjunction");
        int usable = oneCall(currentOwner, controller
                + "->isUsable(Landroid/app/Activity;)Z",
                "lifecycle_owner_conjunction");
        int success = successfulBooleanConstant(currentOwner,
                "lifecycle_owner_conjunction");
        int ownerBranch = -1;
        int ownerResult = moveResultRegister(currentOwner, ownerGet,
                "lifecycle_owner_conjunction");
        for (int index = ownerGet + 2; index < usable; index++) {
            Instruction instruction = currentOwner.code.get(index).instruction;
            if (!"IF_NE".equals(instruction.getOpcode().name())
                    || !(instruction instanceof TwoRegisterInstruction)) continue;
            TwoRegisterInstruction branch = (TwoRegisterInstruction) instruction;
            int other = branch.getRegisterA() == ownerResult
                    ? branch.getRegisterB() : branch.getRegisterB() == ownerResult
                    ? branch.getRegisterA() : -1;
            if (other >= 0 && "PARAM:0".equals(localOrigin(currentOwner,
                    index, other))) ownerBranch = index;
        }
        int generationComparison = -1;
        for (Integer comparison : opcodeIndexes(currentOwner, "CMP_LONG")) {
            Instruction23x cmp = (Instruction23x)
                    currentOwner.code.get(comparison).instruction;
            String left = localOrigin(currentOwner, comparison, cmp.getRegisterB());
            String right = localOrigin(currentOwner, comparison, cmp.getRegisterC());
            if ((left.equals("FIELD:" + controller + "->ownerGeneration:J")
                    && right.equals("PARAM:1"))
                    || (right.equals("FIELD:" + controller + "->ownerGeneration:J")
                    && left.equals("PARAM:1"))) generationComparison = comparison;
        }
        int generationGuard = generationComparison < 0 ? -1
                : comparisonBranchAny(currentOwner, generationComparison,
                "lifecycle_owner_conjunction");
        int usableGuard = consumingBranch(currentOwner, usable, 5, "IF_EQZ",
                "lifecycle_owner_conjunction");
        require(ownerBranch >= 0 && generationComparison >= 0
                && "IF_NEZ".equals(viewOpcode(currentOwner, generationGuard))
                && ownerBranch < generationComparison
                && generationGuard < usable && usableGuard < success,
                "lifecycle_owner_conjunction");
        for (int guard : new int[] { ownerBranch, generationGuard, usableGuard }) {
            List<Integer> paths = normalSuccessors(currentOwner, guard);
            require(paths.size() == 2
                    && canReach(currentOwner, paths.get(0), success, -1)
                    != canReach(currentOwner, paths.get(1), success, -1),
                    "lifecycle_owner_conjunction");
        }
    }

    private static void proveStore(Map<String, ClassDef> classes) throws Failure {
        String store = "Lthreadsmod/update/UpdateStore;";
        String manifest = "Lthreadsmod/update/UpdateManifest;";
        View load = exactMethod(classes, store, "load",
                "(Landroid/content/Context;J)" + manifest, "store_load");
        require((load.method.getAccessFlags() & 0x20000) != 0,
                "store_load_unsynchronized");
        int uncertain = fieldIndex(load, store + "->policyPersistenceUncertain:Z", 0);
        int getAll = oneCall(load,
                "Landroid/content/SharedPreferences;->getAll()Ljava/util/Map;",
                "store_load_getall_count");
        require(uncertain >= 0 && uncertain < getAll,
                "store_uncertain_load_order");
        int uncertaintyBranch = -1;
        for (int index = uncertain + 1; index < getAll; index++) {
            if ("IF_NEZ".equals(viewOpcode(load, index))) uncertaintyBranch = index;
        }
        require(uncertaintyBranch >= 0,
                "store_uncertain_load_guard");
        List<Integer> uncertaintyPaths = normalSuccessors(load, uncertaintyBranch);
        require(uncertaintyPaths.size() == 2
                && canReach(load, uncertaintyPaths.get(0), getAll, -1)
                != canReach(load, uncertaintyPaths.get(1), getAll, -1),
                "store_uncertain_load_bypass");
        int parsedStored = oneCall(load, manifest
                + "->parseStored(Ljava/lang/String;)" + manifest,
                "store_load_envelope_binding");
        List<Integer> rawLongs = calls(load, "Ljava/lang/Long;->longValue()J");
        require(rawLongs.size() == 2, "store_load_envelope_binding");
        int loadRevisionBinding = -1;
        int loadBuildBinding = -1;
        for (Integer comparison : opcodeIndexes(load, "CMP_LONG")) {
            Instruction23x cmp = (Instruction23x)
                    load.code.get(comparison).instruction;
            try {
                String receiver = fieldLoadObjectOrigin(load, comparison,
                        cmp.getRegisterB(), manifest + "->revision:J",
                        "store_load_envelope_binding");
                require(receiver.startsWith("RESULT:" + manifest
                        + "->parseStored"), "store_load_envelope_binding");
                requireCallResultDefinition(load, comparison, cmp.getRegisterC(),
                        rawLongs.get(0), "store_load_envelope_binding");
                loadRevisionBinding = comparison;
            } catch (Failure ignored) { }
            try {
                String receiver = fieldLoadObjectOrigin(load, comparison,
                        cmp.getRegisterB(), manifest + "->modBuild:J",
                        "store_load_envelope_binding");
                require(receiver.startsWith("RESULT:" + manifest
                        + "->parseStored"), "store_load_envelope_binding");
                requireCallResultDefinition(load, comparison, cmp.getRegisterC(),
                        rawLongs.get(1), "store_load_envelope_binding");
                loadBuildBinding = comparison;
            } catch (Failure ignored) { }
        }
        require(parsedStored >= 0 && loadRevisionBinding >= 0
                && loadBuildBinding > loadRevisionBinding
                && "IF_NEZ".equals(viewOpcode(load,
                comparisonBranchAny(load, loadRevisionBinding,
                "store_load_envelope_binding")))
                && "IF_NEZ".equals(viewOpcode(load,
                comparisonBranchAny(load, loadBuildBinding,
                "store_load_envelope_binding"))),
                "store_load_envelope_binding");

        View install = exactMethod(classes, store, "installVerified",
                "(Landroid/content/Context;" + manifest + "J)" + manifest,
                "store_install");
        require((install.method.getAccessFlags() & 0x20000) != 0,
                "store_install_unsynchronized");
        int commit = oneCall(install,
                "Landroid/content/SharedPreferences$Editor;->commit()Z",
                "store_commit_count");
        require(calls(install,
                "Landroid/content/SharedPreferences$Editor;->apply()V").isEmpty(),
                "store_async_commit");
        String putLong = "Landroid/content/SharedPreferences$Editor;"
                + "->putLong(Ljava/lang/String;J)"
                + "Landroid/content/SharedPreferences$Editor;";
        int persistedRevision = oneCallWithStringArgument(install, putLong,
                "update_revision", "store_persisted_revision_binding");
        int[] persistedRevisionArgs = invokeRegisters(
                install.code.get(persistedRevision).instruction);
        require(persistedRevisionArgs.length == 4
                && "PARAM:1".equals(fieldLoadObjectOrigin(install,
                persistedRevision, persistedRevisionArgs[2],
                manifest + "->revision:J", "store_persisted_revision_binding")),
                "store_persisted_revision_binding");
        List<Integer> typedFloors = calls(install, store
                + "->typedNonNegativeLong(Ljava/lang/Object;)J");
        require(typedFloors.size() == 2, "stored_envelope_binding");
        int strongest = oneCall(install, "Ljava/lang/Math;->max(JJ)J",
                "stored_envelope_binding");
        int typedRevisionComparison = -1;
        for (Integer comparison : opcodeIndexes(install, "CMP_LONG")) {
            Instruction23x cmp = (Instruction23x)
                    install.code.get(comparison).instruction;
            try {
                require("PARAM:1".equals(fieldLoadObjectOrigin(install,
                        comparison, cmp.getRegisterB(), manifest + "->revision:J",
                        "store_typed_revision_floor")),
                        "store_typed_revision_floor");
                requireCallResultDefinition(install, comparison,
                        cmp.getRegisterC(), typedFloors.get(0),
                        "store_typed_revision_floor");
                typedRevisionComparison = comparison;
            } catch (Failure ignored) { }
        }
        require(typedRevisionComparison >= 0 && "IF_LTZ".equals(viewOpcode(
                install, comparisonBranchAny(install, typedRevisionComparison,
                "store_typed_revision_floor"))),
                "store_typed_revision_floor");
        int revisionBinding = -1;
        int buildBinding = -1;
        for (Integer comparison : opcodeIndexes(install, "CMP_LONG")) {
            if (comparison >= strongest) break;
            Instruction23x cmp = (Instruction23x)
                    install.code.get(comparison).instruction;
            try {
                String receiver = fieldLoadObjectOrigin(install, comparison,
                        cmp.getRegisterB(), manifest + "->revision:J",
                        "stored_envelope_binding");
                require(!"PARAM:1".equals(receiver), "stored_envelope_binding");
                requireCallResultDefinition(install, comparison, cmp.getRegisterC(),
                        typedFloors.get(0), "stored_envelope_binding");
                revisionBinding = comparison;
            } catch (Failure ignored) { }
            try {
                String receiver = fieldLoadObjectOrigin(install, comparison,
                        cmp.getRegisterB(), manifest + "->modBuild:J",
                        "stored_envelope_binding");
                require(!"PARAM:1".equals(receiver), "stored_envelope_binding");
                requireCallResultDefinition(install, comparison, cmp.getRegisterC(),
                        typedFloors.get(1), "stored_envelope_binding");
                buildBinding = comparison;
            } catch (Failure ignored) { }
        }
        require(revisionBinding >= 0 && buildBinding > revisionBinding,
                "stored_envelope_binding");
        require("IF_NEZ".equals(viewOpcode(install,
                comparisonBranchAny(install, revisionBinding,
                "stored_envelope_binding")))
                && "IF_NEZ".equals(viewOpcode(install,
                comparisonBranchAny(install, buildBinding,
                "stored_envelope_binding"))), "stored_envelope_binding");
        int repairMessage = stringIndex(install,
                "update manifest repair requires newer revision", 0);
        int repairComparison = -1;
        for (Integer comparison : opcodeIndexes(install, "CMP_LONG")) {
            if (comparison <= strongest || comparison >= repairMessage) continue;
            Instruction23x cmp = (Instruction23x)
                    install.code.get(comparison).instruction;
            try {
                require("PARAM:1".equals(fieldLoadObjectOrigin(install,
                        comparison, cmp.getRegisterB(), manifest + "->revision:J",
                        "mismatch_repair_revision")), "mismatch_repair_revision");
                repairComparison = comparison;
            } catch (Failure ignored) { }
        }
        require(repairMessage > strongest && repairComparison >= 0,
                "mismatch_repair_revision");
        require("IF_LEZ".equals(viewOpcode(install,
                comparisonBranchAny(install, repairComparison,
                "mismatch_repair_revision"))), "mismatch_repair_revision");
        int envelopeRevisionRollback = findFieldComparison(install, 0, commit,
                manifest + "->revision:J", "PARAM:1", true,
                "stored_revision_build_rollback");
        int envelopeRevisionBranch = comparisonBranchAny(install,
                envelopeRevisionRollback, "stored_revision_build_rollback");
        require("IF_LTZ".equals(viewOpcode(install, envelopeRevisionBranch)),
                "stored_revision_build_rollback");
        List<Integer> envelopeRevisionPaths = normalSuccessors(install,
                envelopeRevisionBranch);
        require(envelopeRevisionPaths.size() == 2
                && canReach(install, envelopeRevisionPaths.get(1), commit, -1)
                && !canReach(install, envelopeRevisionPaths.get(0), commit, -1),
                "stored_revision_build_rollback");
        int envelopeModRollback = findFieldComparison(install,
                envelopeRevisionBranch + 1, commit, manifest + "->modBuild:J",
                "PARAM:1", true, "stored_revision_build_rollback");
        int envelopeModBranch = comparisonBranchAny(install, envelopeModRollback,
                "stored_revision_build_rollback");
        require("IF_LTZ".equals(viewOpcode(install, envelopeModBranch)),
                "stored_revision_build_rollback");
        List<Integer> envelopeModPaths = normalSuccessors(install,
                envelopeModBranch);
        require(envelopeModPaths.size() == 2
                && canReach(install, envelopeModPaths.get(1), commit, -1)
                && !canReach(install, envelopeModPaths.get(0), commit, -1),
                "stored_revision_build_rollback");
        List<Integer> floorWrites = fieldInstructions(install,
                store + "->policyPersistenceFloor:" + manifest, "SPUT");
        List<Integer> uncertainWrites = fieldInstructions(install,
                store + "->policyPersistenceUncertain:Z", "SPUT");
        List<Integer> retainedWrites = fieldInstructions(install,
                store + "->lastVerifiedManifestForEnforcement:" + manifest, "SPUT");
        require(floorWrites.size() == 2 && uncertainWrites.size() == 2
                && retainedWrites.size() == 1,
                floorWrites.size() != 2 || uncertainWrites.size() != 2
                ? "persistence_exception_uncertainty" : "persistence_floor_before_commit");
        int floorWrite = floorWrites.get(0);
        int floorClear = floorWrites.get(1);
        int uncertainWrite = uncertainWrites.get(0);
        int uncertainClear = uncertainWrites.get(1);
        int retainedWrite = retainedWrites.get(0);
        require("PARAM:1".equals(staticWriteOrigin(install, floorWrite,
                "persistence_floor_before_commit")),
                "persistence_floor_before_commit");
        require("CONST:1".equals(staticWriteOrigin(install, uncertainWrite,
                "persistence_uncertainty_order")),
                "persistence_uncertainty_order");
        require("PARAM:1".equals(staticWriteOrigin(install, retainedWrite,
                "persistence_floor_before_commit"))
                && "CONST:0".equals(staticWriteOrigin(install, uncertainClear,
                "persistence_exception_uncertainty"))
                && "CONST:0".equals(staticWriteOrigin(install, floorClear,
                "persistence_exception_uncertainty")),
                "persistence_exception_uncertainty");
        require(floorWrite >= 0 && uncertainWrite > floorWrite
                && commit > uncertainWrite && retainedWrite > commit
                && uncertainClear > retainedWrite && floorClear > uncertainClear,
                "persistence_uncertainty_order");
        int commitBranch = consumingBranch(install, commit, 8, "IF_EQZ",
                "policy_commit_exception");
        require(dominates(install, commitBranch, retainedWrite),
                "store_commit_success_dominance");
        List<Integer> commitPaths = normalSuccessors(install, commitBranch);
        require(commitPaths.size() == 2
                && canReach(install, commitPaths.get(0), retainedWrite, -1)
                != canReach(install, commitPaths.get(1), retainedWrite, -1),
                "store_commit_false_clears_uncertainty");
        for (Integer handler : exceptionalSuccessors(install, commit)) {
            require(!canReach(install, handler, retainedWrite, -1)
                    && !canReach(install, handler, uncertainClear, -1),
                    "store_commit_throw_clears_uncertainty");
        }
        require(countFields(install, manifest + "->revision:J") >= 8,
                "store_revision_floor_binding");
        require(countFields(install, manifest + "->modBuild:J") >= 8,
                "store_modbuild_floor_binding");
        require(countFields(install, manifest + "->versionCode:J") >= 2,
                "store_version_floor_binding");
        List<Integer> releaseChecks = calls(install, manifest
                + "->sameSignedRelease(" + manifest + ")Z");
        List<Integer> binaryChecks = calls(install, manifest
                + "->sameBinary(" + manifest + ")Z");
        require(releaseChecks.size() >= 2, "stored_revision_equivocation");
        require(binaryChecks.size() >= 2, "stored_same_build_identity");
        requireConditionalGuard(install, releaseChecks.get(0), commit, "IF_EQZ",
                "stored_revision_equivocation");
        int previousReturn = -1;
        for (int index = releaseChecks.get(1) + 1;
                index < Math.min(install.code.size(), releaseChecks.get(1) + 12);
                index++) {
            if ("RETURN_OBJECT".equals(viewOpcode(install, index))) {
                previousReturn = index;
                break;
            }
        }
        require(previousReturn >= 0, "store_revision_equivocation");
        requireGuardedCall(install, releaseChecks.get(1), previousReturn, "IF_EQZ",
                "stored_revision_equivocation");
        for (Integer check : binaryChecks) {
            requireConditionalGuard(install, check, commit, "IF_EQZ",
                    "stored_same_build_identity");
        }
        List<Integer> versionMonotonicChecks = new ArrayList<>();
        for (Integer comparison : opcodeIndexes(install, "CMP_LONG")) {
            if (comparison <= envelopeModBranch || comparison >= commit) continue;
            Instruction23x cmp = (Instruction23x)
                    install.code.get(comparison).instruction;
            try {
                String candidate = fieldLoadObjectOrigin(install, comparison,
                        cmp.getRegisterB(), manifest + "->versionCode:J",
                        "stored_new_build_version");
                String floor = fieldLoadObjectOrigin(install, comparison,
                        cmp.getRegisterC(), manifest + "->versionCode:J",
                        "stored_new_build_version");
                if ("PARAM:1".equals(candidate) && !candidate.equals(floor)) {
                    versionMonotonicChecks.add(comparison);
                }
            } catch (Failure ignoredCandidate) {
                // This comparison does not bind candidate.versionCode to a
                // distinct persisted or process-local manifest floor.
            }
        }
        require(versionMonotonicChecks.size() == 2,
                "stored_new_build_version");
        for (Integer comparison : versionMonotonicChecks) {
            int branch = comparisonBranchAny(install, comparison,
                    "stored_new_build_version");
            require("IF_LEZ".equals(viewOpcode(install, branch))
                    && dominatesNormal(install, comparison, branch),
                    "stored_new_build_version");
            List<Integer> paths = normalSuccessors(install, branch);
            require(paths.size() == 2
                    && canReach(install, paths.get(1), commit, -1)
                    && !canReach(install, paths.get(0), commit, -1),
                    "stored_new_build_version");
            for (Integer handler : exceptionalSuccessors(install, comparison)) {
                require(!canReach(install, handler, commit, -1),
                        "stored_new_build_version");
            }
        }
        View monotonic = exactMethod(classes, store, "requireMonotonicCandidate",
                "(" + manifest + manifest + ")V",
                "stored_new_build_version");
        int processVersionComparison = findFieldComparison(monotonic, 0,
                monotonic.code.size(), manifest + "->versionCode:J", "PARAM:0",
                true, "stored_new_build_version");
        int processVersionBranch = comparisonBranchAny(monotonic,
                processVersionComparison, "stored_new_build_version");
        require("IF_LEZ".equals(viewOpcode(monotonic, processVersionBranch)),
                "stored_new_build_version");
        List<Integer> processVersionPaths = normalSuccessors(monotonic,
                processVersionBranch);
        int processReturn = opcodeIndex(monotonic, "RETURN_VOID", 0,
                monotonic.code.size());
        require(processReturn >= 0 && processVersionPaths.size() == 2
                && canReach(monotonic, processVersionPaths.get(1), processReturn, -1)
                && !canReach(monotonic, processVersionPaths.get(0), processReturn, -1),
                "stored_new_build_version");
        require(stringIndex(install, "update manifest rollback rejected", 0) >= 0
                && stringIndex(install, "update manifest revision conflicts", 0) >= 0
                && stringIndex(install,
                "update policy changes existing binary identity", 0) >= 0
                && stringIndex(install,
                "update version code rollback rejected", 0) >= 0
                && stringIndex(install,
                "update manifest repair requires newer revision", 0) >= 0,
                "store_failure_routes");
        require(opcodeIndexes(install, "CMP_LONG").size() >= 16,
                "store_rollback_comparison_count");

        View retained = exactMethod(classes, store,
                "hasRetainedRequiredForEnforcement", "(J)Z", "store_retained");
        require((retained.method.getAccessFlags() & 0x20000) != 0,
                "store_retained_unsynchronized");
        require(countFields(retained,
                store + "->lastVerifiedManifestForEnforcement:" + manifest) == 1
                && countFields(retained,
                store + "->policyPersistenceUncertain:Z") == 1,
                "store_retained_boolean_sources");
    }

    private static String viewOpcode(View view, int index) {
        return view.code.get(index).instruction.getOpcode().name();
    }

    private static boolean writesRegister(Instruction instruction, int register) {
        if (!(instruction instanceof OneRegisterInstruction)
                || (instruction.getOpcode().flags & OPCODE_SETS_REGISTER) == 0) {
            return false;
        }
        int destination = ((OneRegisterInstruction) instruction).getRegisterA();
        return destination == register
                || ((instruction.getOpcode().flags & OPCODE_SETS_WIDE_REGISTER) != 0
                && destination + 1 == register);
    }

    private static String[] initialOrigins(View view) {
        String[] result = new String[view.implementation.getRegisterCount()];
        Arrays.fill(result, OTHER_ORIGIN);
        if (view.thisRegister >= 0) result[view.thisRegister] = "THIS";
        for (int parameter = 0; parameter < view.parameters.length; parameter++) {
            int register = view.parameters[parameter];
            result[register] = "PARAM:" + parameter;
            String type = String.valueOf(view.method.getParameterTypes().get(parameter));
            if ((type.equals("J") || type.equals("D")) && register + 1 < result.length) {
                result[register + 1] = "PARAM:" + parameter + ":HIGH";
            }
        }
        return result;
    }

    private static String[] transferOrigins(View view, int index, String[] input)
            throws Failure {
        String[] output = input.clone();
        Instruction instruction = view.code.get(index).instruction;
        if (!(instruction instanceof OneRegisterInstruction)
                || (instruction.getOpcode().flags & OPCODE_SETS_REGISTER) == 0) {
            return output;
        }
        int destination = ((OneRegisterInstruction) instruction).getRegisterA();
        String opcode = instruction.getOpcode().name();
        boolean wide = (instruction.getOpcode().flags & OPCODE_SETS_WIDE_REGISTER) != 0;
        String low = OTHER_ORIGIN;
        String high = OTHER_ORIGIN;
        if (opcode.equals("CHECK_CAST")) {
            low = input[destination];
        } else if (opcode.startsWith("MOVE_RESULT")) {
            require(index > 0, "origin_move_result_without_producer");
            Instruction producer = view.code.get(index - 1).instruction;
            if (isInvoke(producer)) {
                low = "RESULT:" + invokeReference(producer);
            } else if (producer.getOpcode().name().startsWith("FILLED_NEW_ARRAY")) {
                low = "ARRAY:#" + (index - 1);
            } else {
                throw new Failure("origin_move_result_without_producer");
            }
        } else if (opcode.startsWith("MOVE")
                && instruction instanceof TwoRegisterInstruction) {
            int source = ((TwoRegisterInstruction) instruction).getRegisterB();
            low = input[source];
            if (wide && source + 1 < input.length) high = input[source + 1];
        } else if ((opcode.startsWith("IGET") || opcode.startsWith("SGET"))
                && instruction instanceof ReferenceInstruction
                && ((ReferenceInstruction) instruction).getReference()
                instanceof FieldReference) {
            low = "FIELD:" + fieldReference((FieldReference)
                    ((ReferenceInstruction) instruction).getReference());
        } else if (opcode.startsWith("CONST")
                && instruction instanceof WideLiteralInstruction) {
            low = "CONST:" + ((WideLiteralInstruction) instruction).getWideLiteral();
        } else if ((opcode.equals("CONST_STRING") || opcode.equals("CONST_STRING_JUMBO"))
                && instruction instanceof ReferenceInstruction) {
            low = "STRING:" + String.valueOf(
                    ((ReferenceInstruction) instruction).getReference());
        } else if (opcode.equals("NEW_INSTANCE")
                && instruction instanceof ReferenceInstruction
                && ((ReferenceInstruction) instruction).getReference()
                instanceof TypeReference) {
            low = "NEW:" + ((TypeReference)
                    ((ReferenceInstruction) instruction).getReference()).getType()
                    + "#" + index;
        }
        output[destination] = low;
        if (wide && destination + 1 < output.length) output[destination + 1] = high;
        return output;
    }

    private static boolean mergeOrigins(String[] existing, String[] incoming) {
        boolean changed = false;
        for (int register = 0; register < existing.length; register++) {
            String value = existing[register].equals(incoming[register])
                    ? existing[register] : OTHER_ORIGIN;
            if (!value.equals(existing[register])) {
                existing[register] = value;
                changed = true;
            }
        }
        return changed;
    }

    private static void ensureOrigins(View view) throws Failure {
        if (view.origins != null) return;
        String[][] inputs = new String[view.code.size()][];
        inputs[0] = initialOrigins(view);
        List<Integer> pending = new ArrayList<>();
        pending.add(0);
        while (!pending.isEmpty()) {
            int index = pending.remove(pending.size() - 1);
            String[] output = transferOrigins(view, index, inputs[index]);
            for (Integer successor : normalSuccessors(view, index)) {
                if (inputs[successor] == null) {
                    inputs[successor] = output.clone();
                    pending.add(successor);
                } else if (mergeOrigins(inputs[successor], output)) {
                    pending.add(successor);
                }
            }
            for (Integer handler : exceptionalSuccessors(view, index)) {
                if (inputs[handler] == null) {
                    inputs[handler] = inputs[index].clone();
                    pending.add(handler);
                } else if (mergeOrigins(inputs[handler], inputs[index])) {
                    pending.add(handler);
                }
            }
        }
        view.origins = inputs;
    }

    private static String localOrigin(View view, int before, int register)
            throws Failure {
        ensureOrigins(view);
        require(before >= 0 && before < view.code.size()
                && register >= 0 && register < view.implementation.getRegisterCount(),
                "origin_bounds");
        String[] input = view.origins[before];
        return input == null ? null : input[register];
    }

    private static boolean mergeDefinitions(Set<Integer> existing,
            Set<Integer> incoming) {
        int size = existing.size();
        existing.addAll(incoming);
        return existing.size() != size;
    }

    private static Set<Integer> reachingDefinitions(View view, int destination,
            int register, String code) throws Failure {
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
            for (Integer successor : normalSuccessors(view, index)) {
                if (inputs.get(successor) == null) {
                    inputs.set(successor, new HashSet<>(output));
                    pending.add(successor);
                } else if (mergeDefinitions(inputs.get(successor), output)) {
                    pending.add(successor);
                }
            }
            for (Integer handler : exceptionalSuccessors(view, index)) {
                if (inputs.get(handler) == null) {
                    inputs.set(handler, new HashSet<>(input));
                    pending.add(handler);
                } else if (mergeDefinitions(inputs.get(handler), input)) {
                    pending.add(handler);
                }
            }
        }
        Set<Integer> result = inputs.get(destination);
        require(result != null && !result.isEmpty(), code);
        return result;
    }

    private static int oneDefinition(View view, int destination, int register,
            String code) throws Failure {
        Set<Integer> definitions = reachingDefinitions(view, destination, register, code);
        require(definitions.size() == 1 && definitions.iterator().next() >= 0, code);
        return definitions.iterator().next();
    }

    private static void requireCallResultDefinition(View view, int destination,
            int register, int call, String code) throws Failure {
        int definition = oneDefinition(view, destination, register, code);
        require(definition == call + 1
                && viewOpcode(view, definition).startsWith("MOVE_RESULT"), code);
    }

    private static boolean originatesAtDefinition(View view, int destination,
            int register, int targetDefinition, Set<String> visiting)
            throws Failure {
        String key = destination + ":" + register + ":" + targetDefinition;
        if (!visiting.add(key)) return false;
        Set<Integer> definitions = reachingDefinitions(view, destination, register,
                "definition_origin");
        if (definitions.size() != 1) return false;
        int definition = definitions.iterator().next();
        if (definition == targetDefinition) return true;
        if (definition < 0) return false;
        Instruction instruction = view.code.get(definition).instruction;
        if (instruction.getOpcode().name().startsWith("MOVE")
                && !instruction.getOpcode().name().startsWith("MOVE_RESULT")
                && instruction instanceof TwoRegisterInstruction) {
            return originatesAtDefinition(view, definition,
                    ((TwoRegisterInstruction) instruction).getRegisterB(),
                    targetDefinition, visiting);
        }
        return false;
    }

    private static String newTypeAtDefinition(View view, int definition) {
        if (definition < 0) return null;
        Instruction instruction = view.code.get(definition).instruction;
        if (!"NEW_INSTANCE".equals(instruction.getOpcode().name())
                || !(instruction instanceof ReferenceInstruction)
                || !(((ReferenceInstruction) instruction).getReference()
                instanceof TypeReference)) return null;
        return ((TypeReference) ((ReferenceInstruction) instruction).getReference()).getType();
    }

    private static void requireFieldDefinition(View view, int destination,
            int register, String expectedField, String expectedObjectOrigin,
            String code) throws Failure {
        int definition = oneDefinition(view, destination, register, code);
        Instruction instruction = view.code.get(definition).instruction;
        require(instruction instanceof ReferenceInstruction
                && ((ReferenceInstruction) instruction).getReference()
                instanceof FieldReference
                && expectedField.equals(fieldReference((FieldReference)
                ((ReferenceInstruction) instruction).getReference())), code);
        if (expectedObjectOrigin != null) {
            require(instruction instanceof TwoRegisterInstruction
                    && expectedObjectOrigin.equals(localOrigin(view, definition,
                    ((TwoRegisterInstruction) instruction).getRegisterB())), code);
        }
    }

    private static String fieldLoadObjectOrigin(View view, int destination,
            int register, String expectedField, String code) throws Failure {
        int definition = oneDefinition(view, destination, register, code);
        Instruction instruction = view.code.get(definition).instruction;
        require(instruction instanceof ReferenceInstruction
                && ((ReferenceInstruction) instruction).getReference()
                instanceof FieldReference
                && expectedField.equals(fieldReference((FieldReference)
                ((ReferenceInstruction) instruction).getReference()))
                && instruction instanceof TwoRegisterInstruction, code);
        return localOrigin(view, definition,
                ((TwoRegisterInstruction) instruction).getRegisterB());
    }

    private static int findFieldComparison(View view, int start, int end,
            String field, String leftObjectOrigin, boolean rightMustDiffer,
            String code) throws Failure {
        for (int index = Math.max(0, start); index < Math.min(end, view.code.size());
                index++) {
            Instruction instruction = view.code.get(index).instruction;
            if (!(instruction instanceof Instruction23x)
                    || !"CMP_LONG".equals(instruction.getOpcode().name())) continue;
            Instruction23x cmp = (Instruction23x) instruction;
            try {
                String left = fieldLoadObjectOrigin(view, index, cmp.getRegisterB(),
                        field, code);
                String right = fieldLoadObjectOrigin(view, index, cmp.getRegisterC(),
                        field, code);
                if (leftObjectOrigin.equals(left)
                        && (!rightMustDiffer || !leftObjectOrigin.equals(right))) {
                    return index;
                }
            } catch (Failure ignoredCandidate) {
                // This comparison is for a different value-flow pair.
            }
        }
        throw new Failure(code);
    }

    private static int oneCallWithStringArgument(View view, String reference,
            String literal, String code) throws Failure {
        int found = -1;
        for (Integer call : calls(view, reference)) {
            int[] arguments = invokeRegisters(view.code.get(call).instruction);
            boolean hasLiteral = false;
            for (int register : arguments) {
                if (("STRING:" + literal).equals(localOrigin(view, call, register))) {
                    hasLiteral = true;
                }
            }
            if (!hasLiteral) continue;
            require(found < 0, code);
            found = call;
        }
        require(found >= 0, code);
        return found;
    }

    private static int oneEqualsUsing(View view, String receiverOrigin,
            Integer argumentResultCall, String code) throws Failure {
        int found = -1;
        for (Integer call : calls(view,
                "Ljava/lang/String;->equals(Ljava/lang/Object;)Z")) {
            int[] arguments = invokeRegisters(view.code.get(call).instruction);
            if (arguments.length != 2
                    || !receiverOrigin.equals(localOrigin(view, call, arguments[0]))) continue;
            if (argumentResultCall != null) {
                try {
                    requireCallResultDefinition(view, call, arguments[1],
                            argumentResultCall.intValue(), code);
                } catch (Failure mismatch) {
                    continue;
                }
            }
            require(found < 0, code);
            found = call;
        }
        require(found >= 0, code);
        return found;
    }

    private static List<Integer> equalsCallsWithFieldReceiver(View view,
            String field, String objectOrigin) throws Failure {
        List<Integer> result = new ArrayList<>();
        for (Integer call : calls(view,
                "Ljava/lang/String;->equals(Ljava/lang/Object;)Z")) {
            int[] arguments = invokeRegisters(view.code.get(call).instruction);
            if (arguments.length != 2) continue;
            try {
                requireFieldDefinition(view, call, arguments[0], field,
                        objectOrigin, "field_equals_candidate");
                result.add(call);
            } catch (Failure ignoredCandidate) {
                // The receiver is another exact String value.
            }
        }
        return result;
    }

    private static boolean exactKeyArrayAtCall(View view, int call,
            String[] keys) throws Failure {
        int[] arguments = invokeRegisters(view.code.get(call).instruction);
        if (arguments.length != 2) return false;
        Set<Integer> definitions = reachingDefinitions(view, call, arguments[1],
                "exact_key_array_flow");
        if (definitions.size() != 1) return false;
        int move = definitions.iterator().next();
        if (move <= 0 || !viewOpcode(view, move).startsWith("MOVE_RESULT")) return false;
        int producer = move - 1;
        if (!viewOpcode(view, producer).startsWith("FILLED_NEW_ARRAY")) return false;
        int[] registers = invokeRegisters(view.code.get(producer).instruction);
        if (registers.length != keys.length) return false;
        for (int index = 0; index < keys.length; index++) {
            if (!("STRING:" + keys[index]).equals(
                    localOrigin(view, producer, registers[index]))) return false;
        }
        return true;
    }

    private static String definitionOrigin(View view, int definition,
            int register, Set<String> visiting, String code) throws Failure {
        if (definition < 0) {
            for (int parameter = 0; parameter < view.parameters.length; parameter++) {
                if (view.parameters[parameter] == register) return "PARAM:" + parameter;
            }
            return view.thisRegister == register ? "THIS" : "UNDEFINED";
        }
        String key = definition + ":" + register;
        require(visiting.add(key), code + "_cycle");
        Instruction instruction = view.code.get(definition).instruction;
        require(writesRegister(instruction, register), code + "_write");
        String opcode = instruction.getOpcode().name();
        String result;
        if (opcode.startsWith("MOVE") && !opcode.startsWith("MOVE_RESULT")
                && instruction instanceof TwoRegisterInstruction) {
            int source = ((TwoRegisterInstruction) instruction).getRegisterB();
            Set<Integer> sources = reachingDefinitions(view, definition, source,
                    code + "_move_source");
            Set<String> origins = new HashSet<>();
            for (Integer sourceDefinition : sources) {
                origins.add(definitionOrigin(view, sourceDefinition, source,
                        visiting, code));
            }
            require(origins.size() == 1, code + "_move_ambiguous");
            result = origins.iterator().next();
        } else {
            String[] input = view.origins == null ? null : view.origins[definition];
            if (input == null) ensureOrigins(view);
            String[] output = transferOrigins(view, definition, view.origins[definition]);
            result = output[register];
        }
        visiting.remove(key);
        return result;
    }

    private static void requireCmpOrigins(View view, int comparison,
            String left, String right, String code) throws Failure {
        Instruction instruction = view.code.get(comparison).instruction;
        require(instruction instanceof Instruction23x
                && "CMP_LONG".equals(instruction.getOpcode().name()), code + "_shape");
        Instruction23x cmp = (Instruction23x) instruction;
        require(left.equals(localOrigin(view, comparison, cmp.getRegisterB()))
                && right.equals(localOrigin(view, comparison, cmp.getRegisterC())),
                code + "_operands");
    }

    private static void proveRequiredPhi(View view, int comparison, int sink,
            int requiredRegister) throws Failure {
        Instruction cmp = view.code.get(comparison).instruction;
        require(cmp instanceof OneRegisterInstruction, "eligibility_required_cmp_shape");
        int branch = branchUsingRegister(view,
                ((OneRegisterInstruction) cmp).getRegisterA(), comparison + 1, 4,
                "IF_GEZ", "eligibility_required_branch");
        List<Integer> paths = normalSuccessors(view, branch);
        require(paths.size() == 2 && dominates(view, branch, sink),
                "eligibility_required_branch_dominance");
        Set<Integer> definitions = reachingDefinitions(view, sink, requiredRegister,
                "eligibility_required_phi_definitions");
        require(definitions.size() == 2, "eligibility_required_phi_count");
        boolean zeroPath = false;
        boolean onePath = false;
        for (Integer definition : definitions) {
            String origin = definitionOrigin(view, definition, requiredRegister,
                    new HashSet<String>(), "eligibility_required_phi_origin");
            if ("CONST:0".equals(origin)
                    && canReach(view, paths.get(0), definition, -1)
                    && !canReach(view, paths.get(1), definition, -1)) zeroPath = true;
            if ("CONST:1".equals(origin)
                    && canReach(view, paths.get(1), definition, -1)
                    && !canReach(view, paths.get(0), definition, -1)) onePath = true;
        }
        require(zeroPath && onePath, "eligibility_required_phi_values");
    }

    private static void proveSemantics(Map<String, ClassDef> classes) throws Failure {
        proveBootstrap(classes);
        proveSignatureAndMetadata(classes);
        proveEligibility(classes);
        proveRetainedUnavailable(classes);
        proveDialog(classes);
        proveVerifyFile(classes);
        proveDownloadAndInstaller(classes);
        proveStore(classes);
    }

    private static String reference(Reference reference) throws Failure {
        if (reference instanceof MethodReference) {
            return "method:" + methodReference((MethodReference) reference);
        }
        if (reference instanceof FieldReference) {
            return "field:" + fieldReference((FieldReference) reference);
        }
        if (reference instanceof TypeReference) {
            return "type:" + ((TypeReference) reference).getType();
        }
        if (reference instanceof MethodHandleReference) {
            MethodHandleReference handle = (MethodHandleReference) reference;
            return "handle:" + handle.getMethodHandleType() + ":"
                    + reference(handle.getMemberReference());
        }
        if (reference instanceof CharSequence) {
            return "string:" + String.valueOf(reference);
        }
        throw new Failure("unsupported_dex_reference");
    }

    private static String encoded(EncodedValue value) throws Failure {
        if (value == null) return "none";
        if (value instanceof NullEncodedValue) return "null";
        if (value instanceof BooleanEncodedValue || value instanceof ByteEncodedValue
                || value instanceof ShortEncodedValue || value instanceof CharEncodedValue
                || value instanceof IntEncodedValue || value instanceof LongEncodedValue
                || value instanceof FloatEncodedValue || value instanceof DoubleEncodedValue) {
            return "scalar:" + value.getValueType() + ":" + value.toString();
        }
        if (value instanceof StringEncodedValue) {
            return "string:" + ((StringEncodedValue) value).getValue();
        }
        if (value instanceof TypeEncodedValue) {
            return "type:" + ((TypeEncodedValue) value).getValue();
        }
        if (value instanceof FieldEncodedValue) {
            return "field:" + fieldReference(((FieldEncodedValue) value).getValue());
        }
        if (value instanceof EnumEncodedValue) {
            return "enum:" + fieldReference(((EnumEncodedValue) value).getValue());
        }
        if (value instanceof MethodEncodedValue) {
            return "method:" + methodReference(((MethodEncodedValue) value).getValue());
        }
        if (value instanceof MethodHandleEncodedValue) {
            return "handle:" + reference(((MethodHandleEncodedValue) value).getValue());
        }
        if (value instanceof ArrayEncodedValue) {
            StringBuilder result = new StringBuilder("array[");
            for (Object element : ((ArrayEncodedValue) value).getValue()) {
                append(result, encoded((EncodedValue) element));
            }
            return result.append(']').toString();
        }
        throw new Failure("unsupported_encoded_value");
    }

    private static void append(StringBuilder output, String value) {
        output.append(value.length()).append(':').append(value).append(';');
    }

    private static int instructionIndex(Map<Integer, Integer> indexByOffset,
            int offset) throws Failure {
        Integer index = indexByOffset.get(offset);
        require(index != null, "semantic_instruction_boundary");
        return index;
    }

    private static String semanticOpcode(Instruction instruction) {
        String opcode = instruction.getOpcode().name();
        if ("CONST_STRING".equals(opcode) || "CONST_STRING_JUMBO".equals(opcode)) {
            return "CONST_STRING";
        }
        if ("GOTO".equals(opcode) || "GOTO_16".equals(opcode)
                || "GOTO_32".equals(opcode)) {
            return "GOTO";
        }
        return opcode;
    }

    private static boolean isPayloadAlignmentNop(List<Instruction> instructions,
            int index, int rawOffset, Set<Integer> referencedOffsets) {
        if (index <= 0 || index + 1 >= instructions.size()
                || !"NOP".equals(instructions.get(index).getOpcode().name())
                || instructions.get(index).getCodeUnits() != 1
                || (rawOffset & 1) == 0
                || referencedOffsets.contains(rawOffset)) return false;
        Instruction next = instructions.get(index + 1);
        if (!(next instanceof SwitchPayload) && !(next instanceof ArrayPayload)) {
            return false;
        }
        String previous = semanticOpcode(instructions.get(index - 1));
        return "RETURN".equals(previous) || "RETURN_VOID".equals(previous)
                || "RETURN_OBJECT".equals(previous) || "RETURN_WIDE".equals(previous)
                || "THROW".equals(previous) || "GOTO".equals(previous);
    }

    private static String instruction(Instruction instruction, int currentOffset,
            Map<Integer, Integer> indexByOffset,
            Map<Integer, Integer> switchBaseByPayload) throws Failure {
        StringBuilder value = new StringBuilder();
        String opcode = semanticOpcode(instruction);
        append(value, opcode);
        if (!"CONST_STRING".equals(opcode) && !"GOTO".equals(opcode)) {
            append(value, Integer.toString(instruction.getCodeUnits()));
        }
        if (instruction instanceof OneRegisterInstruction) {
            append(value, "a=" + ((OneRegisterInstruction) instruction).getRegisterA());
        }
        if (instruction instanceof TwoRegisterInstruction) {
            append(value, "b=" + ((TwoRegisterInstruction) instruction).getRegisterB());
        }
        if (instruction instanceof Instruction23x) {
            append(value, "c=" + ((Instruction23x) instruction).getRegisterC());
        }
        if (instruction instanceof VariableRegisterInstruction) {
            append(value, "count="
                    + ((VariableRegisterInstruction) instruction).getRegisterCount());
        }
        if (instruction instanceof FiveRegisterInstruction) {
            FiveRegisterInstruction five = (FiveRegisterInstruction) instruction;
            append(value, "c=" + five.getRegisterC());
            append(value, "d=" + five.getRegisterD());
            append(value, "e=" + five.getRegisterE());
            append(value, "f=" + five.getRegisterF());
            append(value, "g=" + five.getRegisterG());
        }
        if (instruction instanceof RegisterRangeInstruction) {
            append(value, "start="
                    + ((RegisterRangeInstruction) instruction).getStartRegister());
        }
        if (instruction instanceof NarrowLiteralInstruction) {
            append(value, "narrow="
                    + ((NarrowLiteralInstruction) instruction).getNarrowLiteral());
        }
        if (instruction instanceof WideLiteralInstruction) {
            append(value, "wide=" + ((WideLiteralInstruction) instruction).getWideLiteral());
        }
        if (instruction instanceof HatLiteralInstruction) {
            append(value, "hat=" + ((HatLiteralInstruction) instruction).getHatLiteral());
        }
        if (instruction instanceof OffsetInstruction) {
            int targetOffset = currentOffset
                    + ((OffsetInstruction) instruction).getCodeOffset();
            append(value, "targetIndex="
                    + instructionIndex(indexByOffset, targetOffset));
        }
        if (instruction instanceof ReferenceInstruction) {
            ReferenceInstruction ref = (ReferenceInstruction) instruction;
            append(value, "refType=" + ref.getReferenceType());
            append(value, reference(ref.getReference()));
        }
        if (instruction instanceof DualReferenceInstruction) {
            DualReferenceInstruction dual = (DualReferenceInstruction) instruction;
            append(value, "refType2=" + dual.getReferenceType2());
            append(value, reference(dual.getReference2()));
        }
        if (instruction instanceof SwitchPayload) {
            Integer switchBase = switchBaseByPayload.get(currentOffset);
            require(switchBase != null, "semantic_switch_owner");
            for (Object object : ((SwitchPayload) instruction).getSwitchElements()) {
                SwitchElement element = (SwitchElement) object;
                append(value, "switch=" + element.getKey() + ":"
                        + instructionIndex(indexByOffset,
                        switchBase + element.getOffset()));
            }
        }
        if (instruction instanceof ArrayPayload) {
            ArrayPayload payload = (ArrayPayload) instruction;
            append(value, "width=" + payload.getElementWidth());
            for (Object element : payload.getArrayElements()) {
                append(value, "array=" + String.valueOf(element));
            }
        }
        return value.toString();
    }

    private static String canonicalClass(ClassDef classDef) throws Failure {
        StringBuilder result = new StringBuilder();
        append(result, "class");
        append(result, classDef.getType());
        append(result, Integer.toString(classDef.getAccessFlags()));
        append(result, classDef.getSuperclass() == null ? "" : classDef.getSuperclass());
        for (Object iface : classDef.getInterfaces()) append(result, "iface:" + iface);

        List<Field> fields = new ArrayList<>();
        for (Object field : classDef.getStaticFields()) fields.add((Field) field);
        for (Object field : classDef.getInstanceFields()) fields.add((Field) field);
        Collections.sort(fields, new Comparator<Field>() {
            public int compare(Field left, Field right) {
                return fieldReference(left).compareTo(fieldReference(right));
            }
        });
        for (Field field : fields) {
            append(result, "field");
            append(result, fieldReference(field));
            append(result, Integer.toString(field.getAccessFlags()));
            append(result, encoded(field.getInitialValue()));
        }

        List<Method> methods = new ArrayList<>();
        for (Object method : classDef.getDirectMethods()) methods.add((Method) method);
        for (Object method : classDef.getVirtualMethods()) methods.add((Method) method);
        Collections.sort(methods, new Comparator<Method>() {
            public int compare(Method left, Method right) {
                return methodReference(left).compareTo(methodReference(right));
            }
        });
        for (Method method : methods) {
            append(result, "method");
            append(result, methodReference(method));
            append(result, Integer.toString(method.getAccessFlags()));
            MethodImplementation implementation = method.getImplementation();
            if (implementation == null) {
                append(result, "abstract");
                continue;
            }
            append(result, "registers=" + implementation.getRegisterCount());
            List<Instruction> instructions = new ArrayList<>();
            List<Integer> rawOffsets = new ArrayList<>();
            int offset = 0;
            for (Object object : implementation.getInstructions()) {
                Instruction current = (Instruction) object;
                rawOffsets.add(offset);
                instructions.add(current);
                offset += current.getCodeUnits();
            }
            int rawEndOffset = offset;
            Map<Integer, Integer> switchBaseByPayload = new HashMap<>();
            int instructionOffset = 0;
            for (Instruction current : instructions) {
                String opcode = current.getOpcode().name();
                if (("PACKED_SWITCH".equals(opcode) || "SPARSE_SWITCH".equals(opcode))
                        && current instanceof OffsetInstruction) {
                    int payloadOffset = instructionOffset
                            + ((OffsetInstruction) current).getCodeOffset();
                    require(switchBaseByPayload.put(payloadOffset, instructionOffset) == null,
                            "semantic_switch_owner");
                }
                instructionOffset += current.getCodeUnits();
            }
            Set<Integer> referencedOffsets = new HashSet<>();
            instructionOffset = 0;
            for (Instruction current : instructions) {
                if (current instanceof OffsetInstruction) {
                    referencedOffsets.add(instructionOffset
                            + ((OffsetInstruction) current).getCodeOffset());
                }
                if (current instanceof SwitchPayload) {
                    Integer switchBase = switchBaseByPayload.get(instructionOffset);
                    require(switchBase != null, "semantic_switch_owner");
                    for (Object object : ((SwitchPayload) current).getSwitchElements()) {
                        referencedOffsets.add(switchBase
                                + ((SwitchElement) object).getOffset());
                    }
                }
                instructionOffset += current.getCodeUnits();
            }
            List<BaseTryBlock> tries = new ArrayList<>();
            for (Object object : implementation.getTryBlocks()) {
                require(object instanceof BaseTryBlock, "unsupported_try_block");
                BaseTryBlock block = (BaseTryBlock) object;
                tries.add(block);
                referencedOffsets.add(block.getStartCodeAddress());
                referencedOffsets.add(block.getStartCodeAddress()
                        + block.getCodeUnitCount());
                for (Object handlerObject : block.getExceptionHandlers()) {
                    referencedOffsets.add(((ExceptionHandler) handlerObject)
                            .getHandlerCodeAddress());
                }
            }
            boolean[] payloadAlignmentNop = new boolean[instructions.size()];
            Map<Integer, Integer> indexByOffset = new HashMap<>();
            int semanticIndex = 0;
            for (int index = 0; index < instructions.size(); index++) {
                int rawOffset = rawOffsets.get(index);
                indexByOffset.put(rawOffset, semanticIndex);
                payloadAlignmentNop[index] = isPayloadAlignmentNop(
                        instructions, index, rawOffset, referencedOffsets);
                if (!payloadAlignmentNop[index]) semanticIndex++;
            }
            indexByOffset.put(rawEndOffset, semanticIndex);
            instructionOffset = 0;
            for (int instructionIndex = 0; instructionIndex < instructions.size();
                    instructionIndex++) {
                Instruction current = instructions.get(instructionIndex);
                if (!payloadAlignmentNop[instructionIndex]) {
                    append(result, "index="
                            + instructionIndex(indexByOffset, instructionOffset));
                    append(result, instruction(current, instructionOffset,
                            indexByOffset, switchBaseByPayload));
                }
                instructionOffset += current.getCodeUnits();
            }
            Collections.sort(tries,
                    new Comparator<BaseTryBlock>() {
                        public int compare(BaseTryBlock left, BaseTryBlock right) {
                            int compared = Integer.compare(left.getStartCodeAddress(),
                                    right.getStartCodeAddress());
                            if (compared != 0) return compared;
                            return Integer.compare(left.getCodeUnitCount(),
                                    right.getCodeUnitCount());
                        }
            });
            for (BaseTryBlock block : tries) {
                int tryStart = instructionIndex(
                        indexByOffset, block.getStartCodeAddress());
                int tryEnd = instructionIndex(indexByOffset,
                        block.getStartCodeAddress() + block.getCodeUnitCount());
                append(result, "try=" + tryStart + ":" + tryEnd);
                for (Object handlerObject : block.getExceptionHandlers()) {
                    ExceptionHandler handler = (ExceptionHandler) handlerObject;
                    append(result, "catch="
                            + (handler.getExceptionType() == null ? "*"
                            : handler.getExceptionType()) + ":"
                            + instructionIndex(indexByOffset,
                            handler.getHandlerCodeAddress()));
                }
            }
        }
        return result.toString();
    }

    private static String hex(byte[] bytes) {
        char[] result = new char[bytes.length * 2];
        char[] alphabet = "0123456789abcdef".toCharArray();
        for (int index = 0; index < bytes.length; index++) {
            int value = bytes[index] & 0xff;
            result[index * 2] = alphabet[value >>> 4];
            result[index * 2 + 1] = alphabet[value & 15];
        }
        return new String(result);
    }

    private static Map<String, ClassDef> readPrimaryDex(String apkPath, String dexName)
            throws Exception {
        Map<String, ClassDef> classes = new HashMap<>();
        int primaryCount = 0;
        Set<String> names = new HashSet<>();
        try (ZipFile apk = new ZipFile(apkPath)) {
            List<? extends ZipEntry> entries = Collections.list(apk.entries());
            for (ZipEntry entry : entries) {
                require(names.add(entry.getName()), "duplicate_archive_entry");
                if (entry.isDirectory() || !dexName.equals(entry.getName())) continue;
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
        require(primaryCount == 1, "primary_dex_count");
        return classes;
    }

    private static String semanticDigest(Map<String, ClassDef> all, String prefix,
            int expectedCount, String[] roots) throws Exception {
        List<ClassDef> updater = new ArrayList<>();
        for (ClassDef classDef : all.values()) {
            if (classDef.getType().startsWith(prefix)
                    || classDef.getType().equals("Lthreadsmod/bootstrap/ModBootstrap;")
                    || classDef.getType().startsWith(
                    "Lthreadsmod/bootstrap/ModBootstrap$")) updater.add(classDef);
        }
        require(updater.size() == expectedCount, "updater_class_count");
        for (String root : roots) require(all.containsKey(root), "updater_root_missing");
        Collections.sort(updater, new Comparator<ClassDef>() {
            public int compare(ClassDef left, ClassDef right) {
                return left.getType().compareTo(right.getType());
            }
        });
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        for (ClassDef classDef : updater) {
            String canonical = canonicalClass(classDef);
            digest.update(canonical.getBytes(StandardCharsets.UTF_8));
        }
        return hex(digest.digest());
    }

    private static void emitFailure(String code, String observedHash) {
        System.out.println("{\"schemaVersion\":1,\"status\":\"failed\",\"contract\":\""
                + CONTRACT + "\",\"code\":\"" + code + "\""
                + (observedHash == null ? "" : ",\"observedSemanticSha256\":\""
                + observedHash + "\"") + "}");
    }

    public static void main(String[] args) {
        try {
            require(args.length == 12, "argument_count");
            String expectedDex = args[1];
            String prefix = args[2];
            String expectedHash = args[3];
            int expectedCount;
            try {
                expectedCount = Integer.parseInt(args[4]);
            } catch (Throwable ignored) {
                throw new Failure("class_count_argument");
            }
            require("classes.dex".equals(expectedDex), "dex_name_argument");
            require("Lthreadsmod/update/".equals(prefix), "prefix_argument");
            require(expectedHash.matches("[0-9a-f]{64}"), "semantic_hash_argument");
            require(expectedCount > 0 && expectedCount <= 64, "class_count_argument");
            String[] roots = new String[7];
            Set<String> rootSet = new HashSet<>();
            for (int index = 0; index < roots.length; index++) {
                roots[index] = args[index + 5];
                require((roots[index].startsWith(prefix)
                        || "Lthreadsmod/bootstrap/ModBootstrap;".equals(roots[index]))
                        && roots[index].endsWith(";") && rootSet.add(roots[index]),
                        "root_argument");
            }
            Map<String, ClassDef> classes = readPrimaryDex(args[0], expectedDex);
            proveSemantics(classes);
            String actualHash = semanticDigest(classes, prefix, expectedCount, roots);
            if (!expectedHash.equals(actualHash)) {
                throw new Failure("update_semantic_hash_mismatch", actualHash);
            }
            System.out.println("{\"schemaVersion\":1,\"status\":\"passed\","
                    + "\"contract\":\"" + CONTRACT + "\",\"dex\":\""
                    + expectedDex + "\",\"updaterClassCount\":" + expectedCount
                    + ",\"semanticSha256\":\"" + actualHash + "\",\"checks\":{"
                    + "\"completeUpdaterGraph\":true,"
                    + "\"normalControlFlow\":true,"
                    + "\"exceptionalControlFlow\":true,"
                    + "\"registerValueFlow\":true,"
                    + "\"bootstrapArbitration\":true,"
                    + "\"signatureAndMetadata\":true,"
                    + "\"eligibilityAndPolicy\":true,"
                    + "\"requiredOptionalDialog\":true,"
                    + "\"explicitUpdateTap\":true,"
                    + "\"retainedUnavailableOnly\":true,"
                    + "\"verifiedFileProvenance\":true,"
                    + "\"currentBinarySerialization\":true,"
                    + "\"lifecycleOwnership\":true,"
                    + "\"storeAntiRollback\":true}}");
        } catch (Failure failure) {
            emitFailure(failure.code, failure.observedHash);
            System.exit(1);
        } catch (Throwable ignored) {
            emitFailure("inspector_internal_failure", null);
            System.exit(1);
        }
    }
}
