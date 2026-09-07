import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.base.BaseTryBlock;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.ExceptionHandler;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MethodImplementation;
import com.android.tools.smali.dexlib2.iface.instruction.FiveRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.OffsetInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.RegisterRangeInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.SwitchElement;
import com.android.tools.smali.dexlib2.iface.instruction.SwitchPayload;
import com.android.tools.smali.dexlib2.iface.instruction.VariableRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Verifies one exact literal-to-call register flow in a method of a signed APK.
 *
 * The intended release-gate contract is deliberately narrow: the instruction
 * immediately before the reviewed invocation must be const-string or
 * const-string/jumbo, it must write the exact invocation argument register, and
 * its value must equal the reviewed literal. Merely finding the class, call and
 * string independently is not sufficient.
 */
public final class DexLiteralCallInspector {
    private static byte[] readAll(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[65536];
        int count;
        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
        return output.toByteArray();
    }

    private static String descriptor(MethodReference method) {
        StringBuilder value = new StringBuilder("(");
        for (Object parameter : method.getParameterTypes()) value.append(parameter);
        return value.append(')').append(method.getReturnType()).toString();
    }

    private static int typeWords(Object type) {
        String descriptor = String.valueOf(type);
        return descriptor.equals("J") || descriptor.equals("D") ? 2 : 1;
    }

    private static int[] invocationRegisters(Instruction instruction) {
        if (!(instruction instanceof VariableRegisterInstruction)) {
            throw new IllegalStateException("reviewed invocation has no register-count interface");
        }
        int count = ((VariableRegisterInstruction) instruction).getRegisterCount();
        if (instruction instanceof RegisterRangeInstruction) {
            int start = ((RegisterRangeInstruction) instruction).getStartRegister();
            int[] registers = new int[count];
            for (int index = 0; index < count; index++) registers[index] = start + index;
            return registers;
        }
        if (instruction instanceof FiveRegisterInstruction) {
            FiveRegisterInstruction five = (FiveRegisterInstruction) instruction;
            int[] available = {
                    five.getRegisterC(), five.getRegisterD(), five.getRegisterE(),
                    five.getRegisterF(), five.getRegisterG()
            };
            if (count < 0 || count > available.length) {
                throw new IllegalStateException("reviewed invocation register count is invalid: " + count);
            }
            int[] registers = new int[count];
            System.arraycopy(available, 0, registers, 0, count);
            return registers;
        }
        throw new IllegalStateException(
                "unsupported reviewed invocation register format: " + instruction.getClass().getName());
    }

    private static boolean isLiteralLoad(Instruction instruction, int register, String literal) {
        String opcode = instruction.getOpcode().name();
        if (!opcode.equals("CONST_STRING") && !opcode.equals("CONST_STRING_JUMBO")) return false;
        if (!(instruction instanceof OneRegisterInstruction)
                || !(instruction instanceof ReferenceInstruction)) return false;
        if (((OneRegisterInstruction) instruction).getRegisterA() != register) return false;
        Reference reference = ((ReferenceInstruction) instruction).getReference();
        return reference instanceof CharSequence && literal.contentEquals((CharSequence) reference);
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\n", "\\n").replace("\r", "\\r");
    }

    private static Iterable<Method> methods(ClassDef classDef) {
        List<Method> methods = new ArrayList<>();
        for (Object method : classDef.getDirectMethods()) methods.add((Method) method);
        for (Object method : classDef.getVirtualMethods()) methods.add((Method) method);
        return methods;
    }

    private static int alternateEntryCount(
            List<Instruction> instructions,
            List<Integer> offsets,
            MethodImplementation implementation,
            int callOffset) {
        int alternateEntries = 0;
        for (int index = 0; index < instructions.size(); index++) {
            Instruction instruction = instructions.get(index);
            int instructionOffset = offsets.get(index);
            if (instruction instanceof OffsetInstruction
                    && instructionOffset + ((OffsetInstruction) instruction).getCodeOffset() == callOffset) {
                alternateEntries++;
            }
            String opcode = instruction.getOpcode().name();
            if ((opcode.equals("PACKED_SWITCH") || opcode.equals("SPARSE_SWITCH"))
                    && instruction instanceof OffsetInstruction) {
                int payloadOffset = instructionOffset
                        + ((OffsetInstruction) instruction).getCodeOffset();
                for (int payloadIndex = 0; payloadIndex < instructions.size(); payloadIndex++) {
                    if (offsets.get(payloadIndex) != payloadOffset) continue;
                    Instruction payloadInstruction = instructions.get(payloadIndex);
                    if (!(payloadInstruction instanceof SwitchPayload)) {
                        throw new IllegalStateException("reviewed switch does not target a switch payload");
                    }
                    for (Object elementObject : ((SwitchPayload) payloadInstruction).getSwitchElements()) {
                        SwitchElement element = (SwitchElement) elementObject;
                        if (instructionOffset + element.getOffset() == callOffset) alternateEntries++;
                    }
                }
            }
        }
        for (Object tryObject : implementation.getTryBlocks()) {
            BaseTryBlock tryBlock = (BaseTryBlock) tryObject;
            for (Object handlerObject : tryBlock.getExceptionHandlers()) {
                ExceptionHandler handler = (ExceptionHandler) handlerObject;
                if (handler.getHandlerCodeAddress() == callOffset) alternateEntries++;
            }
        }
        return alternateEntries;
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 11) {
            System.err.println("usage: DexLiteralCallInspector APK CLASS METHOD METHOD_DESCRIPTOR "
                    + "CALLEE_CLASS CALLEE_METHOD CALLEE_DESCRIPTOR INVOKE_OPCODE "
                    + "STRING_ARGUMENT_INDEX LITERAL EXPECTED_COUNT");
            System.exit(2);
        }

        String apkPath = args[0];
        String classDescriptor = args[1];
        String methodName = args[2];
        String methodDescriptor = args[3];
        String calleeClass = args[4];
        String calleeName = args[5];
        String calleeDescriptor = args[6];
        String invokeOpcode = args[7];
        int stringArgumentIndex = Integer.parseInt(args[8]);
        String literal = args[9];
        int expectedCount = Integer.parseInt(args[10]);
        if (stringArgumentIndex < 0 || literal.isEmpty() || expectedCount != 1) {
            throw new IllegalArgumentException("literal-call contract arguments are outside the reviewed bounds");
        }

        int classCount = 0;
        int methodCount = 0;
        int targetCallCount = 0;
        int matchedCount = 0;
        String matchedDex = null;
        int matchedLiteralOffset = -1;
        int matchedCallOffset = -1;
        int matchedArgumentRegister = -1;
        int matchedAlternateEntries = -1;
        Set<String> dexNames = new HashSet<>();

        try (ZipFile apk = new ZipFile(apkPath)) {
            List<? extends ZipEntry> entries = Collections.list(apk.entries());
            entries.sort((left, right) -> left.getName().compareTo(right.getName()));
            for (ZipEntry entry : entries) {
                if (entry.isDirectory() || !entry.getName().endsWith(".dex")) continue;
                if (!dexNames.add(entry.getName())) {
                    throw new IllegalStateException("duplicate DEX ZIP entry name: " + entry.getName());
                }
                byte[] bytes;
                try (InputStream input = apk.getInputStream(entry)) {
                    bytes = readAll(input);
                }
                DexBackedDexFile dex = new DexBackedDexFile(bytes, 0);
                for (Object classObject : dex.classSection) {
                    ClassDef classDef = (ClassDef) classObject;
                    if (!classDescriptor.equals(classDef.getType())) continue;
                    classCount++;
                    for (Method method : methods(classDef)) {
                        if (!methodName.equals(method.getName())
                                || !methodDescriptor.equals(descriptor(method))) continue;
                        methodCount++;
                        MethodImplementation implementation = method.getImplementation();
                        if (implementation == null) {
                            throw new IllegalStateException("reviewed method has no implementation");
                        }
                        List<Instruction> instructions = new ArrayList<>();
                        List<Integer> offsets = new ArrayList<>();
                        int nextOffset = 0;
                        for (Object instructionObject : implementation.getInstructions()) {
                            Instruction instruction = (Instruction) instructionObject;
                            instructions.add(instruction);
                            offsets.add(nextOffset);
                            nextOffset += instruction.getCodeUnits();
                        }
                        for (int instructionIndex = 0;
                                instructionIndex < instructions.size(); instructionIndex++) {
                            Instruction instruction = instructions.get(instructionIndex);
                            if (instruction.getOpcode().name().equals(invokeOpcode)
                                    && instruction instanceof ReferenceInstruction) {
                                Reference reference = ((ReferenceInstruction) instruction).getReference();
                                if (reference instanceof MethodReference) {
                                    MethodReference callee = (MethodReference) reference;
                                    if (calleeClass.equals(callee.getDefiningClass())
                                            && calleeName.equals(callee.getName())
                                            && calleeDescriptor.equals(descriptor(callee))) {
                                        targetCallCount++;
                                        List<?> parameterTypes = callee.getParameterTypes();
                                        if (stringArgumentIndex >= parameterTypes.size()
                                                || !"Ljava/lang/String;".equals(
                                                        String.valueOf(parameterTypes.get(stringArgumentIndex)))) {
                                            throw new IllegalStateException(
                                                    "reviewed literal argument is not a String parameter");
                                        }
                                        int argumentWord = invokeOpcode.contains("STATIC") ? 0 : 1;
                                        for (int parameter = 0; parameter < stringArgumentIndex; parameter++) {
                                            argumentWord += typeWords(parameterTypes.get(parameter));
                                        }
                                        int[] registers = invocationRegisters(instruction);
                                        if (argumentWord >= registers.length) {
                                            throw new IllegalStateException(
                                                    "reviewed literal argument register is absent from invocation");
                                        }
                                        Instruction previous = instructionIndex == 0
                                                ? null : instructions.get(instructionIndex - 1);
                                        int callOffset = offsets.get(instructionIndex);
                                        int alternateEntries = alternateEntryCount(
                                                instructions, offsets, implementation, callOffset);
                                        if (previous != null
                                                && isLiteralLoad(previous, registers[argumentWord], literal)
                                                && alternateEntries == 0) {
                                            matchedCount++;
                                            matchedDex = entry.getName();
                                            matchedLiteralOffset = offsets.get(instructionIndex - 1);
                                            matchedCallOffset = callOffset;
                                            matchedArgumentRegister = registers[argumentWord];
                                            matchedAlternateEntries = alternateEntries;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (classCount != 1 || methodCount != 1
                || targetCallCount != expectedCount || matchedCount != expectedCount) {
            throw new IllegalStateException(
                    "literal-call contract failed: classes=" + classCount
                            + " methods=" + methodCount
                            + " targetCalls=" + targetCallCount
                            + " matchedLiteralFlows=" + matchedCount
                            + " expected=" + expectedCount);
        }

        System.out.println("{\"status\":\"passed\",\"classDescriptor\":\""
                + escape(classDescriptor) + "\",\"method\":\"" + escape(methodName + methodDescriptor)
                + "\",\"callee\":\"" + escape(calleeClass + "->" + calleeName + calleeDescriptor)
                + "\",\"invokeOpcode\":\"" + escape(invokeOpcode)
                + "\",\"stringArgumentIndex\":" + stringArgumentIndex
                + ",\"literal\":\"" + escape(literal) + "\",\"expectedCount\":" + expectedCount
                + ",\"matchedCount\":" + matchedCount
                + ",\"literalCodeOffset\":" + matchedLiteralOffset
                + ",\"callCodeOffset\":" + matchedCallOffset
                + ",\"argumentRegister\":" + matchedArgumentRegister
                + ",\"alternateEntryCount\":" + matchedAlternateEntries
                + ",\"dex\":\"" + escape(matchedDex) + "\"}");
    }
}
