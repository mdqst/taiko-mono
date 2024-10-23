package softblocks

import (
	"net/http"

	"github.com/ethereum/go-ethereum/core/types"
	"github.com/labstack/echo/v4"
)

// TransactionBatchMarker represents the status of a soft block transactions group.
type TransactionBatchMarker string

// BatchMarker values.
const (
	BatchMarkerEOB TransactionBatchMarker = "end_of_block"
	BatchMarkerEOP TransactionBatchMarker = "end_of_preconf"
)

// SoftBlockParams represents the parameters for building a soft block.
type SoftBlockParams struct {
	// Block parameters
	Timestamp uint64 `json:"timestamp"`
	Coinbase  string `json:"coinbase"`

	// AnchorV2 parameters
	AnchorBlockID   uint64 `json:"anchorBlockID"`
	AnchorStateRoot string `json:"anchorStateRoot"`
}

// TransactionBatch represents a soft block group.
type TransactionBatch struct {
	BlockID          uint64                 `json:"blockId"`
	ID               uint64                 `json:"batchId"`
	TransactionsList string                 `json:"transactions"`
	BatchMarker      TransactionBatchMarker `json:"batchType"`
	Signature        string                 `json:"signature"`
	BlockParams      *SoftBlockParams       `json:"blockParams"`
}

// BuildSoftBlockRequestBody represents a request body when handling
// soft blocks creation requests.
type BuildSoftBlockRequestBody struct {
	TransactionBatch TransactionBatch `json:"transactionBatch"`
}

// CreateOrUpdateBlocksFromBatchResponseBody represents a response body when handling soft
// blocks creation requests.
type BuildSoftBlockResponseBody struct {
	BlockHeader types.Header `json:"blockHeader"`
}

// BuildSoftBlock handles a soft block creation request,
// if the soft block group in request are valid, it will insert the correspoinding new soft
// block to the backend L2 execution engine and return a success response.
//
//		@Description	Insert a group of transactions into a soft block for preconfirmation. If the group is the
//		@Description	first for a block, a new soft block will be created. Otherwise, the transactions will
//		@Description	be appended to the existing soft block. The API will fail if:
//		@Description	1) the block is not soft
//	  @Description	2) block-level parameters are invalid or do not match the current soft block’s parameters
//	  @Description	3) the group ID is not exactly 1 greater than the previous one
//	  @Description	4) the last group of the block indicates no further transactions are allowed
//		@Param  body body BuildSoftBlockRequestBody true "soft block creation request body"
//		@Accept	  json
//		@Produce	json
//		@Success	200		{object} BuildSoftBlockResponseBody
//		@Router		/softBlocks [post]
func (s *SoftBlockAPIServer) BuildSoftBlock(c echo.Context) error {
	return c.NoContent(http.StatusOK)
}

// RemoveSoftBlocksRequestBody represents a request body when resetting the backend
// L2 execution engine soft head.
type RemoveSoftBlocksRequestBody struct {
	NewLastBlockID uint64 `json:"newLastBlockId"`
}

// RemoveSoftBlocksResponseBody represents a response body when resetting the backend
// L2 execution engine soft head.
type RemoveSoftBlocksResponseBody struct {
	LastBlockID         uint64 `json:"lastBlockId"`
	LastProposedBlockID uint64 `json:"lastProposedBlockID"`
	HeadsRemoved        uint64 `json:"headsRemoved"`
}

// RemoveSoftBlocks removes the backend L2 execution engine soft head.
//
//		@Description	 Remove all soft blocks from the blockchain beyond the specified block height,
//	  @Description	 ensuring the latest block ID does not exceed the given height. This method will fail if
//	  @Description	 the block with an ID one greater than the specified height is not a soft block. If the
//	  @Description	 specified block height is greater than the latest soft block ID, the method will succeed
//	  @Description	 without modifying the blockchain.
//		@Param      body body RemoveSoftBlocksRequestBody true "soft blocks removing request body"
//		@Accept			json
//		@Produce		json
//		@Success		200	{object} RemoveSoftBlocksResponseBody
//		@Router			/softBlocks [delete]
func (s *SoftBlockAPIServer) RemoveSoftBlocks(c echo.Context) error {
	return c.NoContent(http.StatusOK)
}

// HealthCheck is the endpoints for probes.
//
//	@Summary		Get current server health status
//	@ID			   	health-check
//	@Accept			json
//	@Produce		json
//	@Success		200	{object} string
//	@Router			/healthz [get]
func (s *SoftBlockAPIServer) HealthCheck(c echo.Context) error {
	return c.NoContent(http.StatusOK)
}