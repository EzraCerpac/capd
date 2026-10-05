extension SharedCapture {
    /// Validates the record invariants used by sync receipts and historical baselines.
    public func validateHistorical() throws {
        try SyncDatabase.validateHistorical(self)
    }
}
