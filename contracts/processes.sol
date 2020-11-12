// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.6.9;
pragma experimental ABIEncoderV2;

import "./base.sol"; // Base contracts (Chained, Owned)
import "./interfaces.sol"; // Common interface for retro compatibility
import "./lib.sol"; // Helpers

contract Processes is IProcessStore, Chained {
    using SafeUint8 for uint8;
    using ERCSupport for address;

    // CONSTANTS AND ENUMS

    /*
    Process Mode flags
    The process mode defines how the process behaves externally. It affects both the Vochain, the contract itself, the metadata and the census origin.

    0x11101111
      ||| ||||
      ||| |||`- autoStart
      ||| ||`-- interruptible
      ||| |`--- dynamicCensus
      ||| `---- encryptedMetadata
      ```------ censusOrigin enum
    */
    uint8 internal constant MODE_AUTO_START = 1 << 0;
    uint8 internal constant MODE_INTERRUPTIBLE = 1 << 1;
    uint8 internal constant MODE_DYNAMIC_CENSUS = 1 << 2;
    uint8 internal constant MODE_ENCRYPTED_METADATA = 1 << 3;
    // Index #4 is not used
    uint8 internal constant MODE_CENSUS_ORIGIN = (1 << 7) | (1 << 6) | (1 << 5); // See `IProcessStore` > CensusOrigin

    /*
    Envelope Type flags
    The envelope type tells how the vote envelope will be formatted and handled. Its value is generated by combining the flags below.

    0x00001111
          ||||
          |||`- serial
          ||`-- anonymous
          |`--- encryptedVote
          `---- uniqueValues
    */
    uint8 internal constant ENV_TYPE_SERIAL = 1 << 0; // Questions are submitted one by one
    uint8 internal constant ENV_TYPE_ANONYMOUS = 1 << 1; // ZK Snarks are used
    uint8 internal constant ENV_TYPE_ENCRYPTED_VOTES = 1 << 2; // Votes are encrypted with the process public key
    uint8 internal constant ENV_TYPE_UNIQUE_VALUES = 1 << 3; // Choices for a question cannot appear twice or more

    // EVENTS

    event NamespaceAddressUpdated(address namespaceAddr);

    // GLOBAL DATA

    address public namespaceAddress; // Address of the namespace contract instance that holds the current state

    // DATA STRUCTS
    struct ProcessResults {
        uint32[][] tally; // The tally for every question, option and value
        uint32 height; // The amount of valid envelopes registered
    }

    struct Process {
        uint8 mode; // The selected process mode. See: https://vocdoni.io/docs/#/architecture/smart-contracts/process?id=flags
        uint8 envelopeType; // One of valid envelope types, see: https://vocdoni.io/docs/#/architecture/smart-contracts/process?id=flags
        address entityAddress; // The address of the Entity (or contract) holding the process
        uint64 startBlock; // Tendermint block number on which the voting process starts
        uint32 blockCount; // Amount of Tendermint blocks during which the voting process should be active
        string metadata; // Content Hashed URI of the JSON meta data (See Data Origins)
        string censusMerkleRoot; // Hex string with the Merkle Root hash of the census
        string censusMerkleTree; // Content Hashed URI of the exported Merkle Tree (not including the public keys)
        Status status; // One of 0 [ready], 1 [ended], 2 [canceled], 3 [paused], 4 [results]
        uint8 questionIndex; // The index of the currently active question (only assembly processes)
        // How many questions are available to vote
        // questionCount >= 1
        uint8 questionCount;
        // How many choices can be made for each question.
        // 1 <= maxCount <= 100
        uint8 maxCount;
        // Determines the acceptable value range.
        // N => valid votes will range from 0 to N (inclusive)
        uint8 maxValue;
        uint8 maxVoteOverwrites; // How many times a vote can be replaced (only the last one counts)
        // Limits up to how much cost, the values of a vote can add up to (if applicable).
        // 0 => No limit / Not applicable
        uint16 maxTotalCost;
        // Defines the exponent that will be used to compute the "cost" of the options voted and compare it against `maxTotalCost`.
        // totalCost = Σ (value[i] ** costExponent) <= maxTotalCost
        //
        // Exponent range:
        // - 0 => 0.0000
        // - 10000 => 1.0000
        // - 65535 => 6.5535
        uint16 costExponent;
        // Self-assign to a certain namespace.
        // This will determine the oracles that listen and react to it.
        // Indirectly, it will also determine the Vochain that hosts this process.
        uint16 namespace;
        bytes32 paramsSignature; // entity.sign({...}) // fields that the oracle uses to authentify process creation
        ProcessResults results; // results wraps the tally, the total number of votes, a list of signatures and a list of proofs
    }

    /// @notice An entry for each process created by an Entity.
    /// @notice Keeps track of when it was created and what index this process has within the entire history of the Entity.
    /// @notice Use this to determine whether a process index belongs to the current instance or to a predecessor one.
    struct ProcessCheckpoint {
        uint256 index; // The index of this process within the entity's history, including predecessor instances
    }

    // PER-PROCESS DATA

    mapping(address => ProcessCheckpoint[]) internal entityCheckpoints; // Array of ProcessCheckpoint indexed by entity address
    mapping(bytes32 => Process) internal processes; // Mapping of all processes indexed by the Process ID

    // MODIFIERS

    /// @notice Fails if the msg.sender is not an authorired oracle
    modifier onlyOracle(bytes32 processId) override {
        // Only an Oracle within the process' namespace is valid
        INamespaceStore namespace = INamespaceStore(namespaceAddress);
        require(
            namespace.isOracle(processes[processId].namespace, msg.sender),
            "Not oracle"
        );
        _;
    }

    // HELPERS

    function getEntityProcessCount(address entityAddress)
        public
        override
        view
        returns (uint256)
    {
        if (entityCheckpoints[entityAddress].length == 0) {
            // Not found locally
            if (predecessorAddress == address(0x0)) return 0; // No predecessor to ask

            // Ask the predecessor
            // Note: The predecessor's method needs to follow the old version's signature
            IProcessStore predecessor = IProcessStore(predecessorAddress);
            return predecessor.getEntityProcessCount(entityAddress);
        }

        return
            entityCheckpoints[entityAddress][entityCheckpoints[entityAddress]
                .length - 1]
                .index + 1;
    }

    /// @notice Get the next process ID to use for an entity
    function getNextProcessId(address entityAddress, uint16 namespace)
        public
        override
        view
        returns (bytes32)
    {
        // From 0 to N-1, the next index is N
        uint256 processCount = getEntityProcessCount(entityAddress);
        return getProcessId(entityAddress, processCount, namespace);
    }

    /// @notice Compute the process ID
    function getProcessId(
        address entityAddress,
        uint256 processCountIndex,
        uint16 namespace
    ) public override pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(entityAddress, processCountIndex, namespace)
            );
    }

    // GLOBAL METHODS

    /// @notice Creates a new instance of the contract and sets the contract owner (see Owned).
    /// @param predecessor The address of the predecessor instance (if any). `0x0` means no predecessor (see Chained).
    constructor(address predecessor, address namespace) public {
        Chained.setPredecessor(predecessor);

        namespaceAddress = namespace;
    }

    function setNamespaceAddress(address namespace) public onlyContractOwner {
        require(isContract(namespace), "Invalid namespace");
        namespaceAddress = namespace;

        emit NamespaceAddressUpdated(namespace);
    }

    // GETTERS

    /// @notice Retrieves all the stored fields for the given processId
    function get(bytes32 processId)
        public
        override
        view
        returns (
            uint8[2] memory mode_envelopeType, // [mode, envelopeType]
            address entityAddress,
            string[3] memory metadata_censusMerkleRoot_censusMerkleTree, // [metadata, censusMerkleRoot, censusMerkleTree]
            uint64 startBlock, // startBlock
            uint32 blockCount, // blockCount
            Status status, // status
            uint8[5]
                memory questionIndex_questionCount_maxCount_maxValue_maxVoteOverwrites, // [questionIndex, questionCount, maxCount, maxValue, maxVoteOverwrites]
            uint16[3] memory maxTotalCost_costExponent_namespace
        )
    {
        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask

            // Ask the predecessor
            // Note: The predecessor's method needs to follow the old version's signature
            IProcessStore predecessor = IProcessStore(predecessorAddress);
            return predecessor.get(processId);
        }

        Process storage proc = processes[processId];
        mode_envelopeType = [proc.mode, proc.envelopeType];
        entityAddress = proc.entityAddress;
        metadata_censusMerkleRoot_censusMerkleTree = [
            proc.metadata,
            proc.censusMerkleRoot,
            proc.censusMerkleTree
        ];
        startBlock = proc.startBlock;
        blockCount = proc.blockCount;
        status = proc.status;
        questionIndex_questionCount_maxCount_maxValue_maxVoteOverwrites = [
            proc.questionIndex,
            proc.questionCount,
            proc.maxCount,
            proc.maxValue,
            proc.maxVoteOverwrites
        ];
        maxTotalCost_costExponent_namespace = [
            proc.maxTotalCost,
            proc.costExponent,
            proc.namespace
        ];
    }

    /// @notice Gets the signature of the process parameters, so that authentication can be performed on the Vochain as well
    function getParamsSignature(bytes32 processId)
        public
        override
        view
        returns (bytes32)
    {
        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask

            // Ask the predecessor
            // Note: The predecessor's method needs to follow the old version's signature
            IProcessStore predecessor = IProcessStore(predecessorAddress);
            return predecessor.getParamsSignature(processId);
        }
        Process storage proc = processes[processId];
        return proc.paramsSignature;
    }

    /// @notice Fetch the results of the given processId, if any
    function getResults(bytes32 processId)
        public
        override
        view
        returns (uint32[][] memory tally, uint32 height)
    {
        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask

            // Ask the predecessor
            // Note: The predecessor's method needs to follow the old version's signature
            IProcessStore predecessor = IProcessStore(predecessorAddress);
            return predecessor.getResults(processId);
        }
        // Found locally
        ProcessResults storage results = processes[processId].results;
        return (results.tally, results.height);
    }

    /// @notice Gets the address of the process instance where the given processId was originally created.
    /// @notice This allows to know where to send update transactions, after a fork has occurred.
    function getCreationInstance(bytes32 processId)
        public
        override
        view
        returns (address)
    {
        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask

            // Ask the predecessor
            // Note: The predecessor's method needs to follow the old version's signature
            IProcessStore predecessor = IProcessStore(predecessorAddress);
            return predecessor.getCreationInstance(processId);
        }

        // Found locally
        return address(this);
    }

    // ENTITY METHODS

    function newProcess(
        uint8[2] memory mode_envelopeType, // [mode, envelopeType]
        string[3] memory metadata_merkleRoot_merkleTree, //  [metadata, merkleRoot, merkleTree]
        address tokenContractAddress,
        uint64 startBlock,
        uint32 blockCount,
        uint8[4] memory questionCount_maxCount_maxValue_maxVoteOverwrites, // [questionCount, maxCount, maxValue, maxVoteOverwrites]
        uint16[2] memory maxTotalCost_costExponent, // [maxTotalCost, costExponent]
        uint16 namespace,
        bytes32 paramsSignature
    ) public override onlyIfActive {
        uint8 mode = mode_envelopeType[0];

        // Sanity checks

        if (mode & MODE_AUTO_START != 0) {
            require(startBlock > 0, "Auto start requires a start block");
        }
        if (mode & MODE_INTERRUPTIBLE == 0) {
            require(blockCount > 0, "Uninterruptible needs blockCount");
        }

        if (
            CensusOrigin((mode & MODE_CENSUS_ORIGIN) >> 5) ==
            CensusOrigin.EXPLICIT
        ) {
            // Explicit census
            require(
                bytes(metadata_merkleRoot_merkleTree[1]).length > 0,
                "No merkleRoot"
            );
            require(
                bytes(metadata_merkleRoot_merkleTree[2]).length > 0,
                "No merkleTree"
            );
        } else {
            // EVM based census
            require(
                CensusOrigin((mode & MODE_CENSUS_ORIGIN) >> 5) <=
                    CensusOrigin.MINI_ME,
                "Invalid census origin value"
            );
            require(
                mode & MODE_DYNAMIC_CENSUS != 0,
                "EVM based censuses need dynamic census enabled"
            );
            require(
                tokenContractAddress != address(0x0),
                "Token contract address must be provided"
            );

            // check entity address is contract
            require(isContract(tokenContractAddress), "Not a contract");
            require(tokenContractAddress.supportsBalanceOf(), "Not a contract");
        }

        require(
            bytes(metadata_merkleRoot_merkleTree[0]).length > 0,
            "No metadata"
        );
        require(
            questionCount_maxCount_maxValue_maxVoteOverwrites[0] > 0,
            "No questionCount"
        );
        require(
            questionCount_maxCount_maxValue_maxVoteOverwrites[1] > 0 &&
                questionCount_maxCount_maxValue_maxVoteOverwrites[1] <= 100,
            "Invalid maxCount"
        );
        require(
            questionCount_maxCount_maxValue_maxVoteOverwrites[2] > 0,
            "No maxValue"
        );

        // Process creation

        // Index the process for the entity
        uint256 prevCount = getEntityProcessCount(tokenContractAddress);

        entityCheckpoints[tokenContractAddress].push();
        uint256 cIdx = entityCheckpoints[tokenContractAddress].length - 1;
        ProcessCheckpoint storage checkpoint;
        checkpoint = entityCheckpoints[tokenContractAddress][cIdx];
        checkpoint.index = prevCount;

        Status status;
        if (mode & MODE_AUTO_START != 0) {
            // Auto-start enabled processes start in READY state
            status = Status.READY;
        } else {
            // By default, processes start PAUSED (auto start disabled)
            status = Status.PAUSED;
        }

        // Store the new process
        bytes32 processId = getProcessId(
            tokenContractAddress,
            prevCount,
            namespace
        );
        Process storage processData = processes[processId];

        processData.mode = mode_envelopeType[0];
        processData.envelopeType = mode_envelopeType[1];

        processData.startBlock = startBlock;
        processData.blockCount = blockCount;
        processData.metadata = metadata_merkleRoot_merkleTree[0];

        if (
            CensusOrigin((mode & MODE_CENSUS_ORIGIN) >> 5) ==
            CensusOrigin.EXPLICIT
        ) {
            processData.entityAddress = msg.sender;
            processData.censusMerkleRoot = metadata_merkleRoot_merkleTree[1];
            processData.censusMerkleTree = metadata_merkleRoot_merkleTree[2];
        } else {
            processData.entityAddress = tokenContractAddress;

            // TODO: store block number?
        }

        processData.status = status;
        // processData.questionIndex = 0;
        processData
            .questionCount = questionCount_maxCount_maxValue_maxVoteOverwrites[0];
        processData
            .maxCount = questionCount_maxCount_maxValue_maxVoteOverwrites[1];
        processData
            .maxValue = questionCount_maxCount_maxValue_maxVoteOverwrites[2];
        processData
            .maxVoteOverwrites = questionCount_maxCount_maxValue_maxVoteOverwrites[3];
        processData.maxTotalCost = maxTotalCost_costExponent[0];
        processData.costExponent = maxTotalCost_costExponent[1];
        processData.namespace = namespace;
        processData.paramsSignature = paramsSignature;

        emit NewProcess(processId, namespace);
    }

    function setStatus(bytes32 processId, Status newStatus) public override {
        require(
            uint8(newStatus) <= uint8(Status.PAUSED), // [READY 0..3 PAUSED] => RESULTS (4) is not allowed
            "Invalid status code"
        );

        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask
            revert("Not found: Try on predecessor");
        }

        // Only the process creator
        require(
            processes[processId].entityAddress == msg.sender,
            "Invalid entity"
        );

        Status currentStatus = processes[processId].status;
        if (currentStatus != Status.READY && currentStatus != Status.PAUSED) {
            // When currentStatus is [ENDED, CANCELED, RESULTS], no update is allowed
            revert("Process terminated");
        } else if (currentStatus == Status.PAUSED) {
            // newStatus can only be [READY, ENDED, CANCELED, PAUSED] (see the require above)

            if (processes[processId].mode & MODE_INTERRUPTIBLE == 0) {
                // Is not interruptible, we can only go from PAUSED to READY, the first time
                require(newStatus == Status.READY, "Not interruptible");
            }
        } else {
            // currentStatus is READY

            if (processes[processId].mode & MODE_INTERRUPTIBLE == 0) {
                // If not interruptible, no status update is allowed
                revert("Not interruptible");
            }

            // newStatus can only be [READY, ENDED, CANCELED, PAUSED] (see require above).
        }

        // If currentStatus is READY => Can go to [ENDED, CANCELED, PAUSED].
        // If currentStatus is PAUSED => Can go to [READY, ENDED, CANCELED].
        require(newStatus != currentStatus, "Must differ");

        // Note: the process can also be ended from incrementQuestionIndex
        // If questionIndex is already at the last one
        processes[processId].status = newStatus;

        emit StatusUpdated(
            processId,
            processes[processId].namespace,
            newStatus
        );
    }

    function incrementQuestionIndex(bytes32 processId) public override {
        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask
            revert("Not found: Try on predecessor");
        }

        // Only the process creator
        require(
            processes[processId].entityAddress == msg.sender,
            "Invalid entity"
        );
        // Only if READY
        require(
            processes[processId].status == Status.READY,
            "Process not ready"
        );
        // Only when the envelope is in serial mode
        require(
            processes[processId].envelopeType & ENV_TYPE_SERIAL != 0,
            "Process not serial"
        );

        uint8 nextIdx = processes[processId].questionIndex.add8(1);

        if (nextIdx < processes[processId].questionCount) {
            processes[processId].questionIndex = nextIdx;

            // Not at the last question yet
            emit QuestionIndexUpdated(
                processId,
                processes[processId].namespace,
                nextIdx
            );
        } else {
            // The last question was currently active => End the process
            processes[processId].status = Status.ENDED;

            emit StatusUpdated(
                processId,
                processes[processId].namespace,
                Status.ENDED
            );
        }
    }

    function setCensus(
        bytes32 processId,
        string memory censusMerkleRoot,
        string memory censusMerkleTree
    ) public override onlyIfActive {
        require(bytes(censusMerkleRoot).length > 0, "No Merkle Root");
        require(bytes(censusMerkleTree).length > 0, "No Merkle Tree");

        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask
            revert("Not found: Try on predecessor");
        }

        // Only the process creator
        require(
            processes[processId].entityAddress == msg.sender,
            "Invalid entity"
        );
        // Only if active
        require(
            processes[processId].status == Status.READY ||
                processes[processId].status == Status.PAUSED,
            "Process terminated"
        );
        // Only when the census is dynamic
        require(
            processes[processId].mode & MODE_DYNAMIC_CENSUS != 0,
            "Read-only census"
        );

        processes[processId].censusMerkleRoot = censusMerkleRoot;
        processes[processId].censusMerkleTree = censusMerkleTree;

        emit CensusUpdated(processId, processes[processId].namespace);
    }

    function setResults(
        bytes32 processId,
        uint32[][] memory tally,
        uint32 height
    ) public override onlyOracle(processId) {
        require(height > 0, "No votes");

        if (processes[processId].entityAddress == address(0x0)) {
            // Not found locally
            if (predecessorAddress == address(0x0)) revert("Not found"); // No predecessor to ask
            revert("Not found: Try on predecessor");
        }

        require(
            tally.length == processes[processId].questionCount,
            "Invalid tally"
        );

        // cannot publish results on a canceled process or on a process
        // that already has results
        require(
            processes[processId].status != Status.CANCELED &&
                processes[processId].status != Status.RESULTS,
            "Canceled or already set"
        );

        processes[processId].results.tally = tally;
        processes[processId].results.height = height;
        processes[processId].status = Status.RESULTS;

        emit ResultsAvailable(processId);
    }
}
