package TestHelpers;

import Logging :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import GetPut :: *;
import FixedPoint :: *;
import FIFO :: *;
import SafeRandom :: *;

import "BDPI" function ActionValue#(Bit#(64)) random_init(String name);
import "BDPI" function ActionValue#(Bit#(64)) random_init_seed(String name, Bit#(32) seed);
import "BDPI" function ActionValue#(Bit#(32)) random_next(Bit#(64) ptr);
import "BDPI" function Action random_destroy(Bit#(64) ptr);

interface Randomizer#(type a);
    method Action init();
    method ActionValue#(a) next();
    method Action destroy();
endinterface

module mkGenericRandomizer#(String name)(Randomizer#(a)) provisos (Bits#(a,sa),Bounded#(a));
    `ifdef SEED
        let seed = tagged Valid `SEED;
    `else
        let seed = tagged Invalid;
    `endif
    (*hide*) let _a <- mkGenericRandomizerSeed(seed, name);
    return _a;
endmodule

module mkGenericRandomizerSeed#(Maybe#(Bit#(32)) seed, String name)(Randomizer#(a)) provisos (Bits#(a, sa),Bounded#(a));
    a min = minBound;
    a max = maxBound;
    let _m <- mkConstrainedRandomizerSeed(seed, name, min, max);
    return _m;
endmodule

module mkConstrainedRandomizer#(String name, a minV, a maxV)(Randomizer#(a)) provisos (Bits#(a,sa));
    `ifdef SEED
        let seed = tagged Valid `SEED;
    `else
        let seed = tagged Invalid;
    `endif
    (*hide*) let _a <- mkConstrainedRandomizerSeed(seed, name, minV, maxV);
    return _a;
endmodule

module mkConstrainedRandomizerSeed#(Maybe#(Bit#(32)) seed, String name, a minV, a maxV)(Randomizer#(a)) provisos (Bits#(a,sa));
    Logger logger <- mkLogger(name);
    Reg#(Bit#(64)) ptr <- mkRegU;
    Reg#(Bool) initialized <- mkReg(False);
    Bit#(sa) min = pack(minV);
    Bit#(sa) max = pack(maxV);

    method Action init();
        if (!initialized) begin
            initialized <= True;
            Bit#(64) p;
            case (seed) matches
                tagged Valid .seed: p <- random_init_seed(name, seed);
                tagged Invalid: p <- random_init(name);
            endcase
            ptr <= p;
        end
    endmethod

    method ActionValue#(a) next();
        if (!initialized) begin
            logger.log(ERROR, $format("Not initialized!"));
            $finish();
        end
        Bit#(sa) value = 0;
        Integer i = 0;
        for (i = 0; i <= valueOf(sa); i = i + 32) begin
            Bit#(32) x <- random_next(ptr);
            value = truncate({value, x});
        end
        if ((1 + (max - min)) == 0)
            value = min + value;
        else
            value = min + (value % (1 + (max - min)));
        return unpack(value);
    endmethod

    method Action destroy();
        if (initialized)
            random_destroy(ptr);
    endmethod
endmodule

module mkStructRandomizer#(String name)(Randomizer#(a)) provisos (Bits#(a,s),SafeRandom#(a));
    Randomizer#(Bit#(s)) random <- mkGenericRandomizer(name);

    method init = random.init;
    method ActionValue#(a) next();
        let v <- random.next();
        return safe(unpack(v));
    endmethod
    method destroy = random.destroy;
endmodule

module mkStructRandomizerSeed#(Maybe#(Bit#(32)) seed, String name)(Randomizer#(a)) provisos (Bits#(a,s),SafeRandom#(a));
    Randomizer#(Bit#(s)) random <- mkGenericRandomizerSeed(seed, name);

    method init = random.init;
    method ActionValue#(a) next();
        let v <- random.next();
        return safe(unpack(v));
    endmethod
    method destroy = random.destroy;
endmodule

interface Scoreboard#(type a);
    interface Put#(a) reference;
    interface Put#(a) dut;
    method Action checkFinished();
    method UInt#(64) matchedCount();
endinterface

module mkScoreboardInorder#(String scoreboardName, Integer fifoDepth)(Scoreboard#(a)) provisos (Bits#(a, __a),Eq#(a),FShow#(a));
    Logger logger <- mkLogger(scoreboardName);
    FIFOF#(Tuple2#(a, UInt#(64))) ref_fifo <- mkSizedBypassFIFOF(fifoDepth);
    FIFOF#(Tuple2#(a, UInt#(64))) dut_fifo <- mkSizedBypassFIFOF(fifoDepth);
    Reg#(UInt#(64)) transaction_counter <- mkReg(0);
    Reg#(Bool) warned_fifo_full <- mkReg(False);
    Reg#(UInt#(64)) cycle_count <- mkReg(0);

    Reg#(UInt#(64)) latency_max <- mkReg(0);
    Reg#(UInt#(64)) latency_min <- mkReg(maxBound);
    Reg#(UInt#(64)) latency_avg <- mkReg(0);

    rule count;
        cycle_count <= cycle_count + 1;
    endrule

    (* fire_when_enabled *)
    rule check;
        match {.dut,.dut_cycle} = dut_fifo.first; dut_fifo.deq();
        match {.reference,.ref_cycle} = ref_fifo.first; ref_fifo.deq();

        let latency = abs(dut_cycle - ref_cycle);

        if (dut != reference) begin
            logger.log(ERROR, $format("Mismatch at transaction %d", transaction_counter));
            logger.log(ERROR, $format("Reference:\t", fshow(reference)));
            logger.log(ERROR, $format("DUT:\t\t", fshow(dut)));
            $finish();
        end
        logger.log(TRACE, $format("Successfully compared transaction #%d with reference (latency: %d)", transaction_counter, latency));

        transaction_counter <= transaction_counter + 1;

        latency_max <= max(latency_max, latency);
        latency_min <= min(latency_min, latency);
        FixedPoint#(65,32) t = fromUInt(transaction_counter + 1);
        latency_avg <= (transaction_counter * latency_avg + latency * 100000) / (transaction_counter + 1);
    endrule

    rule check_full if ((!ref_fifo.notFull || !dut_fifo.notFull) && !warned_fifo_full);
        logger.log(WARN, $format("FIFO full, consider increasing Scoreboard Size."));
        warned_fifo_full <= True;
    endrule

    interface Put reference;
        method Action put(a val);
            ref_fifo.enq(tuple2(val, cycle_count));
        endmethod
    endinterface
    interface Put dut;
        method Action put(a val);
            dut_fifo.enq(tuple2(val, cycle_count));
        endmethod
    endinterface
    method Action checkFinished() if (!ref_fifo.notEmpty || !dut_fifo.notEmpty);
        if (ref_fifo.notEmpty) begin
            logger.log(ERROR, $format("remaining reference values, but no DUT values!"));
        end
        if (dut_fifo.notEmpty) begin
            logger.log(ERROR, $format("remaining DUT values, but no reference values!"));
        end
        logger.log(ALWAYS, $format("Successfully compared %d transactions, no mismatches", transaction_counter));
        if (transaction_counter > 0) logger.log(ALWAYS, $format("Latency min %d max %d avg %d.%1d", latency_min, latency_max, latency_avg / 100000, (latency_avg / 10000) % 10));
    endmethod

    method UInt#(64) matchedCount();
        return transaction_counter;
    endmethod
endmodule

interface ForwardRandomizer#(type element_type);
    interface Put#(element_type) in;
    interface Get#(element_type) out;
endinterface

module mkForwardRandomizer#(String name, UInt#(7) ready_percent)(ForwardRandomizer#(element_type)) provisos (Bits#(element_type, a__));
    let fifo_in <- mkBypassFIFO;
    let fifo_out <- mkBypassFIFO;

    Randomizer#(UInt#(7)) random <- mkConstrainedRandomizer(name, 0, 100);

    rule forward;
        let r <- random.next();
        if (r > ready_percent) begin
            fifo_out.enq(fifo_in.first());
            fifo_in.deq();
        end
    endrule

    interface in = toPut(fifo_in);
    interface out = toGet(fifo_out);
endmodule

endpackage