import Testing
import Kernel
@testable import Streaming

struct RecyclingBufferPoolTests {
    @Test func reusesRecycledBuffer() async {
        let pool = RecyclingBufferPool()
        let first = await pool.obtain(capacity: 100)
        await pool.recycle(first)
        let second = await pool.obtain(capacity: 100)
        #expect(first === second)
    }

    @Test func obtainProvidesRequestedCapacity() async {
        let pool = RecyclingBufferPool()
        let buffer = await pool.obtain(capacity: 256)
        #expect(buffer.capacity >= 256)
        #expect(buffer.count == 256)
    }

    @Test func dropsBuffersBeyondMaxRetained() async {
        let pool = RecyclingBufferPool(maxRetained: 2)
        let a = await pool.obtain(capacity: 10)
        let b = await pool.obtain(capacity: 10)
        let c = await pool.obtain(capacity: 10)
        await pool.recycle(a); await pool.recycle(b); await pool.recycle(c)   // c dropped: free capped at 2
        let r1 = await pool.obtain(capacity: 10)
        let r2 = await pool.obtain(capacity: 10)
        let r3 = await pool.obtain(capacity: 10)
        #expect(r1 === a || r1 === b)
        #expect(r2 === a || r2 === b)
        #expect(r3 !== a && r3 !== b && r3 !== c)   // only 2 retained -> third obtain is fresh
    }

    @Test func doesNotReuseBufferTooSmallForRequest() async {
        let pool = RecyclingBufferPool()
        let small = await pool.obtain(capacity: 100)
        await pool.recycle(small)
        let larger = await pool.obtain(capacity: 200)
        #expect(larger !== small)
        #expect(larger.capacity >= 200)
        #expect(larger.count == 200)
    }

    @Test func reusesBufferWhenCapacityExceedsRequest() async {
        let pool = RecyclingBufferPool()
        let big = await pool.obtain(capacity: 100)
        await pool.recycle(big)
        let smallerRequest = await pool.obtain(capacity: 50)
        #expect(smallerRequest === big)
        #expect(smallerRequest.count == 50)
    }
}
