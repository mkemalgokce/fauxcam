import Testing
import Kernel
@testable import Streaming

struct RecyclingBufferPoolTests {
    @Test func reusesRecycledBuffer() async {
        let pool = RecyclingBufferPool()
        let first = await pool.obtain(capacity: 100)
        await pool.recycle(first)
        let second = await pool.obtain(capacity: 100)
        #expect(first === second)   // same instance reused, no new allocation
    }

    @Test func obtainProvidesRequestedCapacity() async {
        let pool = RecyclingBufferPool()
        let buffer = await pool.obtain(capacity: 256)
        #expect(buffer.capacity >= 256)
        #expect(buffer.count == 256)
    }
}
