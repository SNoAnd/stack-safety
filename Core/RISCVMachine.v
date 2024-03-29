Require Coq.Strings.String. Open Scope string_scope.
Require Import Coq.Lists.List.
Import List.ListNotations.
Require Import Bool.

From StackSafety Require Import MachineModule PolicyModule.

Require Import coqutil.Word.Naive.
Require Import coqutil.Word.Properties.
Require Import riscv.Spec.Machine.
Require Import riscv.Spec.Decode.
Require Import Coq.ZArith.BinInt. Local Open Scope Z_scope.

Require Import riscv.Spec.Machine.
Require Import riscv.Utility.Utility.
Require Import riscv.Platform.Memory.
Require Import riscv.Platform.Minimal.
Require Import riscv.Platform.MinimalLogging.
Require Import riscv.Platform.Run.
Require Import riscv.Utility.Monads.
Require Import riscv.Utility.MonadNotations.
Require Import riscv.Utility.MkMachineWidth.
Require Import riscv.Utility.Encode.
Require Import riscv.Utility.InstructionCoercions. Open Scope ilist_scope.
Require Import coqutil.Map.Interface.
Require Import coqutil.Word.LittleEndian.
Require Import riscv.Utility.Words32Naive.
Require Import riscv.Utility.DefaultMemImpl32.
Require Import coqutil.Map.Z_keyed_SortedListMap.
Require Import coqutil.Z.HexNotation.
Require coqutil.Map.SortedList.

Require Import Lia.

From RecordUpdate Require Import RecordSet.
Import RecordSetNotations.

From QuickChick Require Import QuickChick.

Module RISCV <: Machine.
  Export RiscvMachine.

  Axiom exception : forall {A}, string -> A.
  Extract Constant exception =>
            "(fun l ->
            let s = Bytes.create (List.length l) in
            let rec copy i = function
                | [] -> s
                | c :: l -> Bytes.set s i c; copy (i+1) l
                in failwith (""Exception: "" ^ Bytes.to_string (copy 0 l)))".

  Definition Word := MachineInt.
  Definition Value := Word.

  Definition vtow (v:Value) : Word := v.
  Definition ztow (z:Z) : Word := z.
  Definition wtoz (w:Word) : Z := w.
  
  (* Parameter Word *)
  Definition Addr : Type := Word.

   Instance ShowWord : Show word :=
     {| show x := show (word.signed x) |}.

  Definition wlt : Word -> Word -> bool := Z.ltb.

  Definition weq : Word -> Word -> bool := Z.eqb.

  Definition WordEqDec : forall (w1 w2 : Word), {w1 = w2} + {w1 <> w2} := Z.eq_dec.

  Lemma weq_implies_eq :
    forall w1 w2,
      weq w1 w2 = true -> w1 = w2.
  Proof.
    apply Z.eqb_eq.
  Qed.

  Definition wle (w1 w2: Word) : bool :=
    orb (wlt w1 w2) (weq w1 w2).

  Definition wplus (w : Word) (n : Z) : Word :=
    w + n.

  Definition wminus (w : Word) (n : Z) : Word :=
    w - n.

  Lemma wplus_neq : forall w (n : Z),
      (n > 0)%Z -> w <> wplus w n.
  Proof.
    intros w n H Contra.
    unfold wplus in *.
    lia.
  Qed.

  Definition Register : Type := Word.

  Definition Zero := 0.
  Definition RA := 1.
  Definition SP := 2.
  Definition Reg_eq_dec :
    forall (r1 r2 : Register),
      { r1 = r2 } + { r1 <> r2 } := Z.eq_dec.

  Inductive Sec :=
  | sealed
  | free
  | object
  | public
  .

  (* Defaults as per the RISC-V ABI *)
  Definition reg_defaults (r : Register) : Sec :=
    match r with
    | 0 | 2 => public
    | 1 => sealed
    | 5 | 6 | 7 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 28 | 29 | 30 | 31 =>
      sealed (* other caller-saved (+ RA) *)
    | 8 | 9 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 | 26 | 27 =>
      public (* other callee-saved (+ SP) *)
    | 3 | 4 =>
      public (* neither caller- nor callee-saved (+ R0) *)
    | _ => free
    end.

  Lemma RA_sealed : reg_defaults RA = sealed.
  Proof.
    reflexivity.
  Qed.

  Lemma SP_public : reg_defaults SP = public.
  Proof.
    reflexivity.
  Qed.

  Inductive Element :=
  | Mem (a:Addr)
  | Reg (r:Register)
  | PC.

  (* Derive Show for Element. *)

  Definition keqb (k1 k2 : Element) : bool :=
    match k1, k2 with
    | Mem a1, Mem a2 => Z.eqb a1 a2
    | Reg r1, Reg r2 => if Reg_eq_dec r1 r2 then true else false
    | PC, PC => true
    | _, _ => false
    end.

  (* We use a risc-v machine as our machine state *)
  Definition MachineState := RiscvMachine.

  (* Project what we care about from the RiscV state. *)
  Definition proj (m:  MachineState) (k: Element):  Word :=
    match k with
    | Mem a =>
      match (Spec.Machine.loadWord Spec.Machine.Execute (word.of_Z a)) m with
      | (Some w, _) => regToZ_signed (int32ToReg w)
      | (_, _) => 0
      end
    | Reg r =>
      match (Spec.Machine.getRegister r) m with
      | (Some w, _) => word.signed w
      | (_, _) => 0
      end
    | PC =>
      match (Spec.Machine.getPC) m with
      | (Some w, _) => word.signed w
      | (_, _) => 0
      end
    end.

  Definition projw (m:MachineState) (k:Element) := vtow (proj m k).

  Instance etaMachineState : Settable _ :=
    settable! mkRiscvMachine <getRegs; getPc; getNextPc; getMem; getXAddrs; getLog>.

  (* Maybe name this pullback instead *)
  Definition jorp (m : MachineState) (k : Element) (v : Value) : MachineState :=
    match k with
    | Mem a =>
      withMem
        (unchecked_store_byte_list (word.of_Z a)
                                   (Z32s_to_bytes [v]) (getMem m)) m
    | Reg r => 
      withRegs (map.put (getRegs m) r (word.of_Z v)) m
    | PC =>
      withPc (word.of_Z v) m
    end.

  Definition jorpw (m : MachineState) (k : Element) (w : Word) : MachineState :=
    match k with
    | Mem a =>
      withMem
        (unchecked_store_byte_list (word.of_Z a)
                                   (Z32s_to_bytes [w]) (getMem m)) m
    | Reg r => 
      withRegs (map.put (getRegs m) r (word.of_Z w)) m
    | PC =>
      withPc (word.of_Z w) m
    end.
  
  Definition getElements (m : MachineState) : list Element :=
    (* PC *)
    let pc := [PC] in
    (* Non-zero registers. *)
    let regs :=
        List.map (fun x => Reg x) 
                 (List.rev
                    (map.fold (fun acc z v => z :: acc) nil 
                              (RiscvMachine.getRegs m))) in
    (* Non-zero memory-locs. *)
    let mem :=
        List.rev
          (map.fold (fun acc w v =>
                       let z := word.unsigned w in
                       if Z.eqb (snd (Z.div_eucl z 4)) 0
                       then (Mem z) :: acc else acc) nil 
                    (RiscvMachine.getMem m)) in
    pc ++ regs ++ mem.

  Definition Event : Type := Register*Word.
  
  Definition event_eqb (e1 e2 : Event) : bool :=
    let '(a1, v1) := e1 in
    let '(a2, v2) := e1 in
    andb (weq a1 a2) (weq v1 v2).
  
  (* Observations are values, or silent (tau) *)
  Inductive Observation : Type := 
  | Out (w:Event)
  | Tau.

  Definition obs_eqb (o1 o2 : Observation) : bool :=
    match o1, o2 with
    | Out e1, Out e2 => event_eqb e1 e2
    | Tau, Tau => true
    | _, _ => false
    end.

  Definition listify1 {A} (m : Zkeyed_map A)
    : list (Z * A) :=
    List.rev (map.fold (fun acc z v => (z,v) :: acc) nil m).
  
  (* For now we will only monitor registers for changes. We could monitor
     some memory, but we can't monitor the stack. *)
  Definition findDiff (mOld mNew : MachineState) : option (Register*Word) :=
    match find (fun '(reg,_) => negb (weq (proj mOld (Reg reg)) (proj mNew (Reg reg))))
               (listify1 (getRegs mNew)) with
    | Some (r, _) =>
      Some (r, proj mNew (Reg r))
    | None => None
    end.

  Definition FunID := nat.
  Definition Fun_eq_dec :
    forall f1 f2 : FunID, { f1 = f2 } + { f1 <> f2 }.
  Proof. decide equality. Qed.
  
  Definition StackID := nat.


  Definition StackMap := Addr -> option StackID.

  (* Stack ID of stack pointer *)
  Definition activeStack (sm: StackMap) (m: MachineState) :
    option StackID :=
    sm (proj m (Reg SP)).

  Definition stack_eqb : StackID -> StackID -> bool :=
    Nat.eqb.

  Definition optstack_eqb (o1 o2 : option StackID) : bool :=
    match o1, o2 with
    | Some n1, Some n2 => stack_eqb n1 n2
    | None, None => true
    | _, _ => false
    end.

  Inductive Operation : Type :=
  | Call (f:FunID) (reg_args:list Register) (stk_args:list (Register*Z*Z))
  | Tailcall (f:FunID) (reg_args:list Register) (stk_args:list (Register*Z*Z))
  | Return
  | Alloc (off:Z) (sz:Z)
  | Dealloc (off:Z) (sz:Z)
  .

  Lemma Op_eq_dec (op op' : Operation) :
    {op = op'} + {op <> op'}.
  Proof.
    repeat decide equality; try apply Reg_eq_dec; apply Fun_eq_dec.
  Qed.

  Definition isCall (op : Operation) : bool :=
    match op with
    | Call _ _ _ => true
    | _ => false
    end.

  Definition isTailcall (op : Operation) : bool :=
    match op with
    | Tailcall _ _ _ => true
    | _ => false
    end.

  Definition isReturn (op : Operation) : bool :=
    match op with
    | Return => true
    | _ => false
    end.
  
  Derive Show for Operation.

  Definition CodeMap := Addr -> option (list Operation).
  
  (* FIXME: operations *)
  (* A Machine State can step to a new Machine State plus an Observation. *)
  Definition step (m : MachineState) : MachineState * list Operation * Observation :=
    (* returns option unit * state *)
    let '(_, s') := Run.run1 RV32IM m in
    if Z.eqb (word.unsigned (getPc m))
         (word.unsigned (getPc s'))
    then
      (s', [], Tau)
    else
      match findDiff m s' with
      | Some v => (s', [], Out v)
      | None => (s', [], Tau)
      end.

  Definition instr := InstructionI.

  Definition r0 : Register := 0.
  Definition ra : Register := 1.
  Definition sp : Register := 2.
  Definition a0 : Register := 10.
  Definition a1 : Register := 11.
  
  Definition minReg : Register := 10.
  Definition noRegs : nat := 3%nat.
  Definition maxReg : Register := minReg + Z.of_nat noRegs - 1.
  (* TEMP: Keep argument register(s), in particular those used to pass arguments
     by reference, separate from the rest. This eases bookkeeping if we
     keep them immutable, like e.g. SP. A single register for now. *)
  Definition argReg : Register := maxReg.

  Definition minCalleeReg : Register := 18.
  Definition noCalleeRegs : nat := 3%nat.
  Definition maxCalleeReg : Register := minCalleeReg + Z.of_nat noCalleeRegs - 1.
  
  Definition head (sz : Z) :=
    [(* regular entry sequence *)
      (Sw sp ra 0, []);
      (Addi sp sp sz, [Alloc 0 (4*sz)]);
      (* nop/late entry for tail calls *)
      (Addi r0 r0 0, []);
      (* spill callee-saved registers (currently fixed sequence)
         HACK one word above frame lower bound  *)
      (Sw sp minCalleeReg ((-4*sz) + 12), []);
      (Sw sp (minCalleeReg + 1) ((-4*sz) + 8), []);
      (Sw sp (minCalleeReg + 2) ((-4*sz) + 4), [])
    ].
  
End RISCV.

Module RISCVTagged (P : TagPolicy RISCV) <: Machine.
  Import P.
  Export RISCV.
  
  Definition Word := Word.
  Definition Value : Type := (Word * Tag).
  
  Definition vtow (v:Value) : Word := fst v.
  Definition ztow (z:Z) : Word := ztow z.
  Definition wtoz (w:Word) : Z := w.
  
  Definition Addr := Addr.
  
  Instance ShowWord : Show word :=
    {| show x := show (word.signed x) |}.

  Definition wlt := wlt.
  Definition weq := weq.
  Definition WordEqDec := WordEqDec.
  Definition weq_implies_eq := weq_implies_eq.
  Definition wle := wle.
  Definition wplus := wplus.
  Definition wminus := wminus.
  Definition wplus_neq := wplus_neq.  
  Definition Register := Register.
  Definition RA := RA.
  Definition SP := SP.
  Definition Reg_eq_dec := Reg_eq_dec.

  Inductive Sec :=
  | sealed
  | free
  | object
  | public
  .
  
  Definition coercion0 (s:Sec) :=
    match s with
    | sealed => RISCV.sealed
    | free => RISCV.free
    | object => RISCV.object
    | public => RISCV.public
    end.

  Definition coercion0' (s:RISCV.Sec) :=
    match s with
    | RISCV.sealed => sealed
    | RISCV.free => free
    | RISCV.object => object
    | RISCV.public => public
    end.
  
  Coercion coercion0 : Sec >-> RISCV.Sec.
  Coercion coercion0' : RISCV.Sec >-> Sec.

  Definition reg_defaults (r : Register) : Sec :=
    match r with
    | 0 | 2 => public
    | 1 => sealed
    | _ => free
    end.

  Lemma RA_sealed : reg_defaults RA = sealed.
  Proof.
    reflexivity.
  Qed.

  Lemma SP_public : reg_defaults SP = public.
  Proof.
    reflexivity.
  Qed.

  Inductive Element :=
  | Mem (a:Addr)
  | Reg (r:Register)
  | PC.

  Definition coercion1 (k:Element) :=
    match k with
    | Mem a => RISCV.Mem a
    | Reg r => RISCV.Reg r
    | PC => RISCV.PC
    end.

  Definition coercion2 (k:RISCV.Element) :=
    match k with
    | RISCV.Mem a => Mem a
    | RISCV.Reg r => Reg r
    | RISCV.PC => PC
    end.
  
  Coercion coercion1 : Element >-> RISCV.Element.
  Coercion coercion2 : RISCV.Element >-> Element.
  
  Definition keqb : Element -> Element -> bool := keqb.

  Definition MachineState : Type := MPState.

  Definition proj (m : MachineState) (k: Element) : Value :=
    let '(m,p) := m in
    (projw m k, projt p k).

  Definition projw (m : MachineState) (k: Element): Word :=
    let '(m,p) := m in
    projw m k.
  
  Definition jorp (m : MachineState) (k : Element) (v : Value) : MachineState :=
    let '(m,p) := m in
    let '(w,t) := v in
    let m' :=
      match k with
      | Mem a =>
          withMem
            (unchecked_store_byte_list (word.of_Z a)
                                       (Z32s_to_bytes [w]) (getMem m)) m
      | Reg r => 
          withRegs (map.put (getRegs m) r (word.of_Z w)) m
      | PC =>
          withPc (word.of_Z w) m
      end in
    let p' := jorpt p k t in
    (m',p').

  Definition jorpw (m : MachineState) (k : Element) (w : Word) : MachineState :=
    let '(m,p) := m in
    let m' :=
      match k with
      | Mem a =>
          withMem
            (unchecked_store_byte_list (word.of_Z a)
                                       (Z32s_to_bytes [w]) (getMem m)) m
      | Reg r => 
          withRegs (map.put (getRegs m) r (word.of_Z w)) m
      | PC =>
          withPc (word.of_Z w) m
      end in
    (m',p).
  
  Definition getElements (m : MachineState) : list Element :=
    let '(m,p) := m in
    map coercion2 (getElements m).

  Definition Event := Event.
  Definition event_eqb := event_eqb.
    
  Inductive Observation : Type := 
  | Out (w:Event)
  | Tau.

  Definition coercion3 (obs:RISCV.Observation) :=
    match obs with
    | RISCV.Out w => Out w
    | RISCV.Tau => Tau
    end.
  
  Coercion coercion3 : RISCV.Observation >-> Observation.
  
  Definition obs_eqb (o1 o2 : Observation) : bool :=
    match o1, o2 with
    | Out e1, Out e2 => event_eqb e1 e2
    | Tau, Tau => true
    | _, _ => false
    end.

  Definition listify1 {A} (m : Zkeyed_map A)
    : list (Z * A) :=
    List.rev (map.fold (fun acc z v => (z,v) :: acc) nil m).
  
  (* For now we will only monitor registers for changes. We could monitor
     some memory, but we can't monitor the stack. *)
  Definition findDiff (mOld mNew : MachineState) : option (Register*Word) :=
    let '(mOld,pOld) := mOld in
    let '(mNew,pNew) := mNew in
    findDiff mOld mNew.

  Definition FunID := nat.
  Definition Fun_eq_dec := Fun_eq_dec.
  
  Definition StackID := nat.

  Definition StackMap := Addr -> option StackID.

  (* Stack ID of stack pointer *)
  Definition activeStack (sm: StackMap) (m: MachineState) :
    option StackID :=
    sm (projw m (Reg SP)).

  Definition stack_eqb : StackID -> StackID -> bool :=
    Nat.eqb.

  Definition optstack_eqb (o1 o2 : option StackID) : bool :=
    match o1, o2 with
    | Some n1, Some n2 => stack_eqb n1 n2
    | None, None => true
    | _, _ => false
    end.

  Inductive Operation : Type :=
  | Call (f:FunID) (reg_args:list Register) (stk_args:list (Register*Z*Z))
  | Tailcall (f:FunID) (reg_args:list Register) (stk_args:list (Register*Z*Z))
  | Return
  | Alloc (off:Z) (sz:Z)
  | Dealloc (off:Z) (sz:Z)
  .

  Lemma Op_eq_dec (op op' : Operation) :
    {op = op'} + {op <> op'}.
  Proof.
    repeat decide equality; try apply Reg_eq_dec; apply Fun_eq_dec.
  Qed.

  Definition isCall (op : Operation) : bool :=
    match op with
    | Call _ _ _ => true
    | _ => false
    end.

  Definition isTailcall (op : Operation) : bool :=
    match op with
    | Tailcall _ _ _ => true
    | _ => false
    end.

  Definition isReturn (op : Operation) : bool :=
    match op with
    | Return => true
    | _ => false
    end.

  Derive Show for Operation.

  Definition coercion4 (op : RISCV.Operation) :=
    match op with
    | RISCV.Call f reg_args stk_args => Call f reg_args stk_args
    | RISCV.Tailcall f reg_args stk_args => Tailcall f reg_args stk_args
    | RISCV.Return => Return
    | RISCV.Alloc off sz => Alloc off sz
    | RISCV.Dealloc off sz => Dealloc off sz
    end.

  Definition coercion5 (op : Operation) :=
    match op with
    | Call f reg_args stk_args => RISCV.Call f reg_args stk_args
    | Tailcall f reg_args stk_args => RISCV.Tailcall f reg_args stk_args
    | Return => RISCV.Return
    | Alloc off sz => RISCV.Alloc off sz
    | Dealloc off sz => RISCV.Dealloc off sz
    end.
  
  Coercion coercion4 : RISCV.Operation >-> Operation.
  Coercion coercion5 : Operation >-> RISCV.Operation.
  
  Definition CodeMap := Addr -> option (list Operation).
  
  (* TODO: operations *)
  (* A Machine State can step to a new Machine State plus an Observation. *)
  Definition step (m : MachineState) : MachineState * list Operation * Observation :=
    let '(m',ops,obs) := mpstep m in
    (m',map coercion4 ops, coercion3 obs).

  Definition instr : Type := instr * Tag.

  Definition head (sz : Z) : list (instr * list Operation) :=
    map (fun '(a,b,c) => (a,b,map coercion4 c)) (tagify_head sz (head sz)).

End RISCVTagged.
