pragma solidity ^0.4.25;

// It's important to avoid vulnerabilities due to numeric overflow bugs
// OpenZeppelin's SafeMath library, when used correctly, protects agains such bugs
// More info: https://www.nccgroup.trust/us/about-us/newsroom-and-events/blog/2018/november/smart-contract-insecurity-bad-arithmetic/

import "../node_modules/openzeppelin-solidity/contracts/math/SafeMath.sol";

/************************************************** */
/* FlightSurety Smart Contract                      */
/************************************************** */
contract FlightSuretyApp {
    using SafeMath for uint256; // Allow SafeMath functions to be called for all uint256 types (similar to "prototype" in Javascript)

    /********************************************************************************************/
    /*                                       DATA VARIABLES                                     */
    /********************************************************************************************/

    // Flight status codes
    uint8 private constant STATUS_CODE_UNKNOWN = 0;
    uint8 private constant STATUS_CODE_ON_TIME = 10;
    uint8 private constant STATUS_CODE_LATE_AIRLINE = 20;
    uint8 private constant STATUS_CODE_LATE_WEATHER = 30;
    uint8 private constant STATUS_CODE_LATE_TECHNICAL = 40;
    uint8 private constant STATUS_CODE_LATE_OTHER = 50;

    address private contractOwner;          // Account used to deploy contract

    struct Flight {
        string flightNumber;
        bool isRegistered;
        bool landed;
        uint8 statusCode;
        uint256 updatedTimestamp;        
        address airline;
    }
    mapping(bytes32 => Flight) private flights;

    // The factor by which passengers are compensated (initially 1.5x)is stored in the following variables
    // This factor can be modified via the updateCompensatingFactor function
    uint8 public factorNumerator = 3;
    uint8 public factorDenominator = 2;

    /*** Referencing the data contract ***/
    // Adding state variable referencing Data contract
    FlightSuretyData flightSuretyData;

    /********************************************************************************************/
    /*                                       FUNCTION MODIFIERS                                 */
    /********************************************************************************************/

    // Modifiers help avoid duplication of code. They are typically used to validate something
    // before a function is allowed to be executed.

    /**
    * @dev Modifier that requires the "operational" boolean variable to be "true"
    *      This is used on all state changing functions to pause the contract in 
    *      the event there is an issue that needs to be fixed
    */
    modifier requireIsOperational() 
    {
         // Modify to call data contract's status
        require(true, "Contract is currently not operational");  
        _;  // All modifiers require an "_" which indicates where the function body will be added
    }

    /**
    * @dev Modifier that requires the "ContractOwner" account to be the function caller
    */
    modifier requireContractOwner()
    {
        require(msg.sender == contractOwner, "Caller is not contract owner");
        _;
    }

    /**
    * @dev Modifier that requires an airline to be registered
    */
    modifier requireRegisteredAirline()
    {
        require(flightSuretyData.isAirlineRegistered(msg.sender), "Caller is not a registered airline");
        _;
    }

    /**
    * @dev Modifier that requires an airline to be active
    */
    modifier requireActivatedAirline()
    {
        require(flightSuretyData.isAirlineActivated(msg.sender), "Caller is not an activated airline");
        _;
    }

    /********************************************************************************************/
    /*                                       CONSTRUCTOR                                        */
    /********************************************************************************************/

    /**
    * @dev Contract constructor
    *
    */
    constructor
                                (
                                    address dataContract
                                ) 
                                public 
    {
        contractOwner = msg.sender;
        // Initializing state variable that references the data contract
        flightSuretyData = FlightSuretyData(dataContract);
    }

    /********************************************************************************************/
    /*                                       UTILITY FUNCTIONS                                  */
    /********************************************************************************************/

    function isOperational() 
                            public 
                            pure 
                            returns(bool) 
    {
        return true;  // Modify to call data contract's status
    }

    function updateCompensatingFactor   (
                                            uint8 numerator,
                                            uint8 denominator
                                        )
                                        external
                                        requireIsOperational
                                        requireContractOwner
    {
        factorNumerator = numerator;
        factorDenominator = denominator;
    }

    /********************************************************************************************/
    /*                                     SMART CONTRACT FUNCTIONS                             */
    /********************************************************************************************/

  
   /**
    * @dev Add an airline to the registration queue
    *
    */   
    function registerAirline
                            (
                                address newAirline
                            )
                            external
                            requireIsOperational
                            requireActivatedAirline
                            returns(bool success, uint256 votes)
    {
        bool register;
        votes = flightSuretyData.getAirlineVotesCounter(newAirline).add(1);
        if(flightSuretyData.getRegisteredAirlinesCounter() < 4 || votes.mul(100) >= flightSuretyData.getRegisteredAirlinesCounter().mul(100).div(2)) {
            register = true;
        }
        else {
            register = false;
        }
        flightSuretyData.registerAirline(newAirline, register, msg.sender);
        success = flightSuretyData.isAirlineRegistered(newAirline);
        return (success, votes);
    }

   /**
    * @dev Register a future flight for insuring.
    *
    */  
    function registerFlight
                                (
                                    string flight,
                                    uint timestamp
                                )
                                external
                                requireIsOperational
                                requireActivatedAirline
    {
        // Generating a key for registering the flight
        bytes32 key = keccak256(abi.encodePacked(msg.sender, flight, timestamp));
        // Filling in the flight initial data
        flights[key] = Flight ({
                                    flightNumber: flight,
                                    isRegistered: true,
                                    landed: false,
                                    statusCode: 0,
                                    updatedTimestamp: timestamp,
                                    airline: msg.sender
                                    });
        flightSuretyData.registerFlightForInsurance(msg.sender, flight, timestamp, true);
    }
    
   /**
    * @dev Called after oracle has updated flight status
    *
    */  
    function processFlightStatus
                                (
                                    address airline,
                                    string memory flight,
                                    uint256 timestamp,
                                    uint8 statusCode
                                )
                                internal
                                requireIsOperational
    {
        bytes32 key = getFlightKey(airline, flight, timestamp);
        require(flights[key].isRegistered, "This flight is not registered");
        require(!flights[key].landed, "The status of this flight has already been updated");
        flights[key].statusCode = statusCode;
        // Status other than 0 sets the flight landed variable to true
        if(statusCode != 0) {
            flights[key].landed = true;            
        }

        // Passengers are credited if flight is late due to the airline
        if(statusCode == 20) {
            flightSuretyData.creditInsurees(airline, flight, timestamp, factorNumerator, factorDenominator);
        }
    }


    // Generate a request for oracles to fetch flight information
    function fetchFlightStatus
                        (
                            address airline,
                            string flight,
                            uint256 timestamp                            
                        )
                        external
                        requireIsOperational
    {
        bytes32 flightKey = getFlightKey(airline, flight, timestamp);
        require(flights[flightKey].isRegistered, "This flight is not registered");
        require(!flights[flightKey].landed, "The status of this flight has already been updated");
        uint8 index = getRandomIndex(msg.sender);

        // Generate a unique key for storing the request
        bytes32 key = keccak256(abi.encodePacked(index, airline, flight, timestamp));
        oracleResponses[key] = ResponseInfo({
                                                requester: msg.sender,
                                                isOpen: true
                                            });

        emit OracleRequest(index, airline, flight, timestamp);
    }

    // Read the current status of a flight without triggering a OracleRequest event
    function getFlightStatus
                                (
                                    address airline,
                                    string flight,
                                    uint256 timestamp
                                )
                                external
                                view
                                returns (uint8 status)
    {
        bytes32 key = getFlightKey(airline, flight, timestamp);
        status = flights[key].statusCode;
    }


// region ORACLE MANAGEMENT

    // Incremented to add pseudo-randomness at various points
    uint8 private nonce = 0;    

    // Fee to be paid when registering oracle
    uint256 public constant REGISTRATION_FEE = 1 ether;

    // Number of oracles that must respond for valid status
    uint256 private constant MIN_RESPONSES = 3;


    struct Oracle {
        bool isRegistered;
        uint8[3] indexes;        
    }

    // Track all registered oracles
    mapping(address => Oracle) private oracles;

    // Model for responses from oracles
    struct ResponseInfo {
        address requester;                              // Account that requested status
        bool isOpen;                                    // If open, oracle responses are accepted
        mapping(uint8 => address[]) responses;          // Mapping key is the status code reported
                                                        // This lets us group responses and identify
                                                        // the response that majority of the oracles
    }

    // Track all oracle responses
    // Key = hash(index, flight, timestamp)
    mapping(bytes32 => ResponseInfo) private oracleResponses;

    // Event fired each time an oracle submits a response
    event FlightStatusInfo(address airline, string flight, uint256 timestamp, uint8 status);

    event OracleReport(address airline, string flight, uint256 timestamp, uint8 status);

    // Event fired when flight status request is submitted
    // Oracles track this and if they have a matching index
    // they fetch data and submit a response
    event OracleRequest(uint8 index, address airline, string flight, uint256 timestamp);


    // Register an oracle with the contract
    function registerOracle
                            (
                            )
                            external
                            payable
    {
        // Require registration fee
        require(msg.value >= REGISTRATION_FEE, "Registration fee is required");

        uint8[3] memory indexes = generateIndexes(msg.sender);

        oracles[msg.sender] = Oracle({
                                        isRegistered: true,
                                        indexes: indexes
                                    });
    }

    function getMyIndexes
                            (
                            )
                            view
                            external
                            returns(uint8[3])
    {
        require(oracles[msg.sender].isRegistered, "Not registered as an oracle");

        return oracles[msg.sender].indexes;
    }




    // Called by oracle when a response is available to an outstanding request
    // For the response to be accepted, there must be a pending request that is open
    // and matches one of the three Indexes randomly assigned to the oracle at the
    // time of registration (i.e. uninvited oracles are not welcome)
    function submitOracleResponse
                        (
                            uint8 index,
                            address airline,
                            string flight,
                            uint256 timestamp,
                            uint8 statusCode
                        )
                        external
    {
        require((oracles[msg.sender].indexes[0] == index) || (oracles[msg.sender].indexes[1] == index) || (oracles[msg.sender].indexes[2] == index), "Index does not match oracle request");


        bytes32 key = keccak256(abi.encodePacked(index, airline, flight, timestamp)); 
        require(oracleResponses[key].isOpen, "Flight or timestamp do not match oracle request");

        oracleResponses[key].responses[statusCode].push(msg.sender);

        // Information isn't considered verified until at least MIN_RESPONSES
        // oracles respond with the *** same *** information
        emit OracleReport(airline, flight, timestamp, statusCode);
        if (oracleResponses[key].responses[statusCode].length >= MIN_RESPONSES) {
            
            // If the status code is other than '0', the attribute isRegistered in the data contract
            // is set to false in order to prevent any passenger from purchasing the insurance
            if(statusCode != 0)
            {
                flightSuretyData.registerFlightForInsurance(airline, flight, timestamp, false);
                }

            // The request is closed
            oracleResponses[key].isOpen = false;

            emit FlightStatusInfo(airline, flight, timestamp, statusCode);

            // Handle flight status as appropriate
            processFlightStatus(airline, flight, timestamp, statusCode);
        }
    }


    function getFlightKey
                        (
                            address airline,
                            string flight,
                            uint256 timestamp
                        )
                        pure
                        internal
                        returns(bytes32) 
    {
        return keccak256(abi.encodePacked(airline, flight, timestamp));
    }

    // Returns array of three non-duplicating integers from 0-9
    function generateIndexes
                            (                       
                                address account         
                            )
                            internal
                            returns(uint8[3])
    {
        uint8[3] memory indexes;
        indexes[0] = getRandomIndex(account);
        
        indexes[1] = indexes[0];
        while(indexes[1] == indexes[0]) {
            indexes[1] = getRandomIndex(account);
        }

        indexes[2] = indexes[1];
        while((indexes[2] == indexes[0]) || (indexes[2] == indexes[1])) {
            indexes[2] = getRandomIndex(account);
        }

        return indexes;
    }

    // Returns array of three non-duplicating integers from 0-9
    function getRandomIndex
                            (
                                address account
                            )
                            internal
                            returns (uint8)
    {
        uint8 maxValue = 10;

        // Pseudo random number...the incrementing nonce adds variation
        uint8 random = uint8(uint256(keccak256(abi.encodePacked(blockhash(block.number - nonce++), account))) % maxValue);

        if (nonce > 250) {
            nonce = 0;  // Can only fetch blockhashes for last 256 blocks so we adapt
        }

        return random;
    }

// endregion

}

contract FlightSuretyData {

    function registerAirline 
                            (
                                address newAirline,
                                bool register,
                                address endorsingAirline
                            )
                            external;

    function activateAirline
                            (
                                address newAirline
                            )
                            external;

    function isAirlineRegistered
                            (
                                address airline
                            )
                            external
                            view
                            returns (bool);

    function isAirlineActivated
                            (
                                address airline
                            )
                            external
                            view
                            returns (bool);

    function getAirlineVotesCounter 
                                (
                                    address airline
                                )
                                external
                                view
                                returns(uint256);

    function getRegisteredAirlinesCounter
                                (
                                )
                                external
                                view
                                returns(uint256);                                  

    function getActiveAirlinesCounter
                                (
                                )
                                external
                                view
                                returns(uint256);

    function registerFlightForInsurance
                                        (
                                            address airline,
                                            string flight,
                                            uint256 timestamp,
                                            bool registered
                                        )
                                        external;

    function creditInsurees
                                        (
                                            address airline,
                                            string flight,
                                            uint256 timestamp,
                                            uint numerator,
                                            uint denominator
                                        )
                                        external;
    
}
