/*
    This quest involves the new standard of NFTs and requires knowledge of aptos-token-objects smart contract.
    The quest has two main features: breeding NFTs and combining NFTs.
    Breeding requires to have two monster NFTs from the same collection. It freezes transfer of those NFTs for time
    specified while creating a monster collection. After the time passed, owner of the two NFTs can call `hatch_monster`
    function, which unlocks the NFTs and transfers a new one with combine properties to the owner.
    Combining requires to have from 2 to 10 NFTs from the same collection (amount specified while creating equipment
    collection). Owner of the NFTs can call `combine_equipment` function to burn their NFTs and receive a new one with
    combined properties.
*/

module overmind::breeder_core {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::aptos_hash;
    use aptos_std::from_bcs;
    use aptos_std::math64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_token_objects::aptos_token;
    use aptos_token_objects::token::{Self, Token};
    use aptos_token_objects::property_map::{Self, PropertyMap};
    use overmind::breeder_events::{
        Self,
        CreateMonsterCollectionEvent,
        CreateMonsterEvent,
        BreedMonsterEvent,
        HatchMonsterEvent,
        CreateEquipmentCollectionEvent,
        CreateEquipmentEvent,
        CombineEquipmentEvent
    };
    #[test_only]
    use aptos_token_objects::royalty;
    #[test_only]
    use aptos_token_objects::collection;
    #[test_only]
    use aptos_token_objects::collection::Collection;
    #[test_only]
    use std::features;

    ////////////
    // ERRORS //
    ////////////

    const ERROR_SIGNER_NOT_ADMIN: u64 = 0;
    const ERROR_STATE_NOT_INITIALIZED: u64 = 1;
    const ERROR_INVALID_BREEDING_TIME: u64 = 2;
    const ERROR_INVALID_COMBINE_AMOUNT: u64 = 3;
    const ERROR_INVALID_EQUIPMENT_PROPERTY_VALUES_SUM: u64 = 4;
    const ERROR_COLLECTION_ALREADY_EXISTS: u64 = 5;
    const ERROR_COLLECTION_DOES_NOT_EXIST: u64 = 6;
    const ERROR_SIGNER_IS_NOT_THE_OWNER: u64 = 7;
    const ERROR_MONSTER_DURING_BREEDING: u64 = 8;
    const ERROR_MONSTERS_NOT_BREEDING: u64 = 9;
    const ERROR_BREEDING_HAS_NOT_ENDED: u64 = 10;
    const ERROR_INCORRECT_AMOUNT_OF_EQUIPMENT: u64 = 11;
    const ERROR_PROPERTY_LENGTH_MISMATCH: u64 = 12;
    const ERROR_TOKEN_FROM_WRONG_COLLECTION: u64 = 13;

    //////////////
    // PDA Seed //
    //////////////

    const BREEDER_SEED: vector<u8> = b"BREEDER";

    //////////////////////////
    // COLLECTIONS SETTINGS //
    //////////////////////////

    const MONSTER_MAX_SUPPLY: u64 = 10000;
    const EQUIPMENT_MAX_SUPPLY: u64 = 1000;
    const ROYALTY_NUMERATOR: u64 = 1;
    const ROYALTY_DENOMINATOR: u64 = 10;

    ////////////////////////////
    // BREEDING TIME SETTINGS //
    ////////////////////////////

    const MINIMAL_BREEDING_TIME: u64 = 60 * 60 * 24;
    const MAXIMAL_BREEDING_TIME: u64 = 60 * 60 * 24 * 365 / 12;

    ////////////////////////
    // MONSTER PROPERTIES //
    ////////////////////////

    const MONSTER_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Health", b"Defence", b"Strength", b"Ability"];
    const MONSTER_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"u64", b"0x1::string::String"];
    const MONSTER_MINIMAL_START_PROPERTY_VALUES: vector<u64> = vector[10, 0, 1];
    const MONSTER_MAXIMAL_START_PROPERTY_VALUES: vector<u64> = vector[100, 10, 20];

    /////////////////////////////
    // COMBINE AMOUNT SETTINGS //
    /////////////////////////////

    const MINIMAL_AMOUNT_OF_PIECES_TO_COMBINE: u64 = 2;
    const MAXIMAL_AMOUNT_OF_PIECES_TO_COMBINE: u64 = 10;

    //////////////////////////
    // EQUIPMENT PROPERTIES //
    //////////////////////////

    const EQUIPMENT_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Attack", b"Defence", b"Durability", b"Ability"];
    const EQUIPMENT_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"u64", b"0x1::string::String"];
    const EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM: u64 = 10;
    const EQUIPMENT_MAXIMAL_START_PROPERTY_VALUES_SUM: u64 = 100;

    /*
        Resource kept under admin address. Stores data about available collections.
    */
    struct State has key {
        // Breeder instance
        breeder: Breeder,
        // Combiner instance
        combiner: Combiner,
        // PDA's SingerCapability
        cap: SignerCapability
    }

    /*
        Holds data about monster colections and ongoing breedings.
    */
    struct Breeder has store {
        // Available monster collections and their corresponding names
        collections: SimpleMap<String, MonsterRace>,
        // List of ongoing breedings and timestamps of when they going to finish
        ongoing_breedings: SimpleMap<vector<u8>, u64>,
        // Events
        create_monster_collection_events: EventHandle<CreateMonsterCollectionEvent>,
        create_monster_events: EventHandle<CreateMonsterEvent>,
        breed_monster_events: EventHandle<BreedMonsterEvent>,
        hatch_monster_events: EventHandle<HatchMonsterEvent>
    }

    /*
        Holds data about a single monster collection
    */
    struct MonsterRace has store, copy, drop {
        // Amount of time required for two monsters to hatch a new one
        breeding_time: u64,
        // Starting properties of a monster created via create_monster function
        starting_properties: vector<vector<u8>>,
    }

    /*
        Holds data about equipment collections
    */
    struct Combiner has store {
        // Available equipment collections with their corresponding names
        collections: SimpleMap<String, Equipment>,
        // Events
        create_equipment_collection_events: EventHandle<CreateEquipmentCollectionEvent>,
        create_equipment_events: EventHandle<CreateEquipmentEvent>,
        combine_equipment_events: EventHandle<CombineEquipmentEvent>
    }

    /*
        Holds data about a single equipment collection
    */
    struct Equipment has store, copy, drop {
        // Amount of equipment tokens required to combine them into one
        combine_amount: u64,
        // Starting properties of equipment created via create_equipment function
        starting_properties: vector<vector<u8>>
    }

    /*
        Creates a PDA and initializes State resource
        @param admin - signer of the admin account
    */
    public entry fun init(admin: &signer) {
        // TODO: Assert the signer is the admin

        // TODO: Create resource account

        // TODO: Create State instance and move it to the admin
    }

    /*
        Creates a new monster collection and adds it to Breeder's collections.
        @param account - an account signing the transaction
        @param name - name of the new collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param breeding_time - amount of time NFTs will be frozen for while breeding
        @param ability_property - special ability of every NFT in the collection
    */
    public entry fun create_monster_collection(
        _account: &signer,
        name: String,
        description: String,
        uri: String,
        breeding_time: u64,
        ability_property: String
    ) acquires State {
        // TODO: Assert that the state is initialized

        // TODO: Assert that breeding time is correct

        // TODO: Assert that a collection with provided name does not exist

        // TODO: Create a collection

        // TODO: Calculate monster starting properties

        // TODO: Push ability property to the starting properties

        // TODO: Add a new MonsterRace to Breeder's collections

        // TODO: Emit CreateMonsterCollectionEvent event
    }

    /*
        Creates a new equipment collection and adds it to Combiner's collections.
        @param account - signer of the transaction
        @param name - name of the new collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param combine_amount - amount of NFT from this collection required to combined them into one
        @param ability_property - special ability of NFTs from this collection
    */
    public entry fun create_equipment_collection(
        _account: &signer,
        name: String,
        description: String,
        uri: String,
        combine_amount: u64,
        property_values: vector<u64>,
        ability_property: String
    ) acquires State {
        // TODO: Assert that combine amount is correct

        // TODO: Calculate equipment starting properties sum

        // TODO: Assert that sum of provided property_values is correct

        // TODO: Assert that state is initialized

        // TODO: Assert that collection with provided name does not exist

        // TODO: Create a collection

        // TODO: Create a new Equipment and add it to Combiner's collections

        // TODO: Emit CreateEquipmentCollectionEvent event
    }

    /*
        Creates a new monster NFT from provided collection.
        @param account - account, which the newly created token is transfered to
        @param collection_name - name of the collection
        @param monster_name - name of the created monster token
        @param monster_description - description of the created monster token
        @param monster_uri - image's UTI of the created monster token
    */
    public entry fun create_monster(
        account: &signer,
        collection_name: String,
        monster_name: String,
        monster_description: String,
        monster_uri: String
    ) acquires State {
        // TODO: Assert that state is initialized

        // TODO: Assert that collection with provided name exists

        // TODO: Create a variable holding PDA's GUID next creation number

        // TODO: Mint a new NFT

        // TODO: Transfer the NFT to the signer of the transaction

        // TODO: Emit CreateMonsterEvent event
    }

    /*
        Creates a new equipment token from provided collection
        @param account - account, which the newly created token is transfered to
        @param collection_name - name of the collection
        @param equipment_name - name of the created equipment token
        @param equipment_description - description of the created equipment token
        @param equipment_uri - image's UTI of the created equipment token
        @param amount - amount of tokens to be created
    */
    public entry fun create_equipment(
        account: &signer,
        collection_name: String,
        equipment_name: String,
        equipment_description: String,
        equipment_uri: String,
        amount: u64
    ) acquires State {
        // TODO: Assert that state is initialized

        // TODO: Assert that collection with provided name exists

        // TODO: For every token to be created:
        //      1. Create a variable holding PDA's GUID next creation number
        //      2. Mint a new NFT
        //      3. Transfer the NFT to the signer of the transaction

        // TODO: Emit CreateEquipmentEvent event
    }

    /*
        Freezes both provided monster tokens and adds a record to Breeder's ongoing_breedings
        @param owner - owner of the provided monster tokens
        @param collection_name - name of the collection, which the tokens are from
        @param first_monster_creation_number - creation number of the first monster token
        @param second_monster_creation_number - creation number of the second monster token
    */
    public entry fun breed_monsters(
        owner: &signer,
        collection_name: String,
        first_monster_creation_number: u64,
        second_monster_creation_number: u64
    ) acquires State {
        // TODO: Assert that state is initialized

        // TODO: Assert that collection with provided name exists

        // TODO: Assert that the signer owns the first monster token

        // TODO: Assert that the first monster token is from the provided collection

        // TODO: Assert that the first monster is not breeding

        // TODO: Assert that the signer owns the second monster token

        // TODO: Assert that the second monster token is from the provided collection

        // TODO: Assert that the second monster is not breeding

        // TODO: Create a hash from both of monster addresses

        // TODO: Add new record to Breeder's ongoing_breedings

        // TODO: Freeze transfer of both tokens

        // TODO: Emit BreedMonsterEvent event
    }

    /*
        Unfreezes provided monster tokens, creates new one with combined properties and transfers it to the owner.
        @param owner - owner of the two breeding monster tokens
        @param first_monster_creation_number - creation number of the first monster token
        @param second_monster_creation_number - creation number of the second monster token
        @param new_monster_name - name of the new monster token
        @param new_monster_description - description of the new monster token
        @param new_monster_uri - image's URI of the new monster token
    */
    public entry fun hatch_monster(
        owner: &signer,
        first_monster_creation_number: u64,
        second_monster_creation_number: u64,
        new_moster_name: String,
        new_monster_description: String,
        new_monster_uri: String
    ) acquires State {
        // TODO: Assert that state is initialized

        // TODO: Assert that the signer owns the first monster token

        // TODO: Assert that the signer owns the second monster token

        // TODO: Assert that the monsters are breeding

        // TODO: Assert that the breeding has finished

        // TODO: Remove breeding record from Breeder's ongoing_breedings

        // TODO: Unfreeze transfer of both monster tokens

        // TODO: Create a variable and save PDA's GUID next creation number

        // TODO: Combine properties of the monster tokens

        // TODO: Mint a new monster token

        // TODO: Transfer the new monster token to the owner

        // TODO: Emit HatchMonsterEvent event
    }

    /*
        Burns provided equipment tokens, creates new one with combined properties and transfers it to the owner
        @param owner - owner of the provided equipment tokens
        @param collection_name - name of the collection, which the tokens are from
        @param equipment_creation_numbers - list of equipment tokens to be burned
        @param new_equipment_name - name of the new equipment token
        @param new_equipment_description - description of the new equipment token
        @param new_equipment_uri - image's URI of the new equipment token
    */
    public entry fun combine_equipment(
        owner: &signer,
        collection_name: String,
        equipment_creation_numbers: vector<u64>,
        new_equipment_name: String,
        new_equipment_description: String,
        new_equipment_uri: String
    ) acquires State {
        // TODO: Assert that state is initialized

        // TODO: Assert that amount of equipment to burn is correct

        // TODO: Create a vector and for each of equipment's creation numbers:
        //      1. Create Object<PropertyMap>
        //      2. Push it to the vector

        // TODO: Combine properties of the equipment

        // TODO: For each of equipement's creation numbers
        //      1. Assert that the signer owns the token
        //      2. Assert that the token is from the provided collection
        //      3. Burn the token

        // TODO: Save PDA's GUID next creation number

        // TODO: Mint a new equipment NFT with combined properties

        // TODO: Transfer the new equipment NFT to the owner

        // TODO: Emit CombineEquipmentEvent event
    }

    /*
        Returns sum of starting properties for provieded combine amount
        @param combine_amount - amount of equipment tokens that would be combined
        @returns - sum of the starting properties
    */
    #[view]
    public fun get_equipment_starting_properties_sum(combine_amount: u64): u64 {
        // TODO: Assert that provided combine amount is correct

        // TODO: Calcualte and return equipment starting properties sum
    }

    /*
        Wrapper for creating a new collection
        @param creator - creator of the collection
        @param name - name of the collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param supply - supply of the new collection
        @param burnable - states if tokens from the collection are burnable
        @param freezable - states if tokens from the collection are freezable
    */
    inline fun create_collection_internal(
        creator: &signer,
        name: String,
        description: String,
        uri: String,
        supply: u64,
        burnable: bool,
        freezable: bool
    ) {
        // TODO: Call aptos_token::creation_collection function with appropriate parameters
    }

    /*
        Converts byte representation of provided property parameters (keys, types, values) into string representation
        @param property_params - parameters of properties
        @returns - string representation of properties' parameters
    */
    inline fun get_property_params_as_strings(property_params: &vector<vector<u8>>): vector<String> {
        // TODO: Convert vector of byte representations into vector of string representations
    }

    /*
        Calculates starting properties of monsters basing on provided breeding time
        @param breeding_time - time required for monsters to hatch a new one
        @returns - list of starting properties
    */
    inline fun calculate_monster_starting_properties(breeding_time: u64): vector<u64> {
        // TODO: Calculate monster starting properties accordingly to the formula:
        //        (b_t - MIN_B_T)^3
        //      --------------------- * P_Diff + P_Min
        //      (MAX_B_T - MIN_B_T)^3
        // Where:
        //      b_t - breeding_time
        //      MIN_B_T - MINIMAL_BREEDING_TIME
        //      MAX_B_T - MAXIMAL_BREEDING_TIME
        //      P_Diff - Difference between minimal and maximal of one of monster start property values
        //      P_Min - Minimal value of one of monster start property values
    }

    /*
        Calculates sum of starting properties of equipment basing on provided combine amount
        @param combine_amount - amount of equipment tokens required to combine them into one
        @returns - sum of starting properties
    */
    inline fun calculate_equipment_starting_properties_sum(combine_amount: u64): u64 {
        // TODO: Calculate sum of equipment starting properties accordingly to the formula:
        //          (c_a - MIN_AMOUNT)^2
        //      --------------------------- * P_Diff + P_MIN
        //      (MAX_AMOUNT - MIN_AMOUNT)^2
        // Where:
        //      c_a - combine_amount
        //      MIN_AMOUNT - MINIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        //      MAX_AMOUNT - MAXIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        //      P_Diff - Difference between EQUIPMENT_MAXIMAL_START_PROPERTY_VALUES_SUM and
        //          EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM
        //      P_MIN - EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM
    }

    /*
        Calculates combined properties for provided PropertyMap instances
        @param property_keys - property keys of a collection
        @param property_maps - PropertyMap instances of tokens
        @returns - combined property values
    */
    inline fun combine_properties(
        property_keys: vector<String>,
        property_maps: vector<Object<PropertyMap>>
    ): vector<vector<u8>> {
        // TODO: Assert that both vectors have the same length

        // TODO: Create a vector for combined properties

        // TODO: For each of property keys:
        //      1. Read property's type and value from each of property maps
        //          a. If the type is u64, then add it to an accumulator
        //          b. If the type is not u64, then push it to the vector and break looping through property maps
        //      2. If the accumulator does not have any value, then continue to the next iteration
        //      3. Otherwise, push the accumulator's value to the vector
    }

    /////////////
    // ASSERTS //
    /////////////

    inline fun assert_signer_is_admin(admin: &signer) {
        // TODO: Assert that address of the parameter is the same as admin in Move.toml
    }

    inline fun assert_state_initialized() {
        // TODO: Assert that State resource exists at the admin address
    }

    inline fun assert_breeding_time_is_correct(breeding_time: u64) {
        // TODO: Assert that breeding_time is greater or equals to MINIMAL_BREEDING_TIME and is smaller or equals to
        //      MAXIMAL_BREEDING_TIME
    }

    inline fun assert_combine_amount_is_correct(combine_amount: u64) {
        // TODO: Assert that combine_amount is greater or equals to MINIMAL_AMOUNT_OF_PIECES_TO_COMBINE and is smaller
        //      or equals to MAXIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        assert!(
            MINIMAL_AMOUNT_OF_PIECES_TO_COMBINE <= combine_amount &&
                combine_amount <= MAXIMAL_AMOUNT_OF_PIECES_TO_COMBINE,
            ERROR_INVALID_COMBINE_AMOUNT
        );
    }

    inline fun assert_equipment_property_values_sum_is_correct(property_values: &vector<u64>, expected_sum: u64) {
        // TODO: Assert that sum of property_values' values is smaller or equals expected_sum
    }

    inline fun assert_collection_does_not_exist(collections: &vector<String>, collection_name: &String) {
        // TODO: Assert that the vector does not contain the collection's name
    }

    inline fun assert_collection_exists(collections: &vector<String>, collection_name: &String) {
        // TODO: Assert that the vector contains the collection's name
    }

    inline fun assert_signer_owns_token(owner: &signer, token: Object<Token>) {
        // TODO: Assert that address of the owner is the same as the owner of the object
    }

    inline fun assert_monster_not_breeding(monster: Object<Token>) {
        // TODO: Assert that transfer of the object is allowed
    }

    inline fun assert_monsters_are_breeding(
        ongoing_breedings: &SimpleMap<vector<u8>, u64>,
        monster_pair_hash: &vector<u8>
    ) {
        // TODO: Assert that the map contains the provided key
    }

    inline fun assert_breeding_finished(
        ongoing_breedings: &SimpleMap<vector<u8>, u64>,
        monster_pair_hash: &vector<u8>
    ) {
        // TODO: Assert that timestamp related to the provided monster_pair_hash is smaller or equals current timestamp
    }

    inline fun assert_amount_of_equipment_is_correct(equipment: &vector<u64>, combine_amount: u64) {
        // TODO: Assert that the vector's length equals to combine_amount
    }

    inline fun assert_property_vectors_lengths(
        property_keys: &vector<String>,
        properties: &vector<Object<PropertyMap>>
    ) {
        // TODO: Assert that each of the property maps length equals to number of keys in property_keys
    }

    inline fun assert_token_is_from_correct_collection(collection_name: String, token: Object<Token>) {
        // TODO: Assert that collection of the token is the same as collection_name
    }

    ///////////
    // TESTS //
    ///////////

    #[test]
    fun test_create_collection_internal() {
        let creator = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"My new collection");
        let description = string::utf8(b"This is my first collection");
        let uri = string::utf8(b"https://i1.sndcdn.com/artworks-000032011179-v3cdjs-t500x500.jpg");

        create_collection_internal(&creator, name, description, uri, 50, false, false);

        let collection_address = collection::create_collection_address(&@0xCAFE, &name);
        let collection_object = object::address_to_object<Collection>(collection_address);
        assert!(option::is_some(&collection::count(collection_object)), 0);
        assert!(*option::borrow(&collection::count(collection_object)) == 0, 1);
        assert!(collection::creator(collection_object) == @0xCAFE, 2);
        assert!(collection::description(collection_object) == description, 3);
        assert!(collection::name(collection_object) == name, 4);
        assert!(collection::uri(collection_object) == uri, 5);
        assert!(royalty::exists_at(collection_address), 6);

        let maybe_royalty = royalty::get(collection_object);
        assert!(option::is_some(&maybe_royalty), 7);

        let royalty = option::extract(&mut maybe_royalty);
        assert!(royalty::denominator(&royalty) == 10, 8);
        assert!(royalty::numerator(&royalty) == 1, 9);

        assert!(!aptos_token::is_mutable_collection_description(collection_object), 10);
        assert!(!aptos_token::is_mutable_collection_royalty(collection_object), 11);
        assert!(!aptos_token::is_mutable_collection_uri(collection_object), 12);
        assert!(!aptos_token::is_mutable_collection_description(collection_object), 13);
        assert!(!aptos_token::is_mutable_collection_token_name(collection_object), 14);
        assert!(!aptos_token::is_mutable_collection_token_properties(collection_object), 15);
        assert!(!aptos_token::are_collection_tokens_burnable(collection_object), 16);
        assert!(!aptos_token::are_collection_tokens_freezable(collection_object), 17);
    }

    #[test]
    fun test_get_property_params_as_strings() {
        let property_keys = vector[b"First key", b"Second key", b"Third key"];
        let property_keys_strings = get_property_params_as_strings(&property_keys);
        assert!(
            property_keys_strings ==
                vector[
                    string::utf8(b"First key"),
                    string::utf8(b"Second key"),
                    string::utf8(b"Third key")
                ],
            0
        );
    }

    #[test]
    fun test_calculate_monster_starting_properties() {
        let breeding_time = MINIMAL_BREEDING_TIME;
        let starting_properties = calculate_monster_starting_properties(breeding_time);
        assert!(starting_properties == MONSTER_MINIMAL_START_PROPERTY_VALUES, 0);

        let breeding_time = MAXIMAL_BREEDING_TIME;
        let starting_properties = calculate_monster_starting_properties(breeding_time);
        assert!(starting_properties == MONSTER_MAXIMAL_START_PROPERTY_VALUES, 1);

        let breeding_time = 60 * 60 * 24 * 16;
        let starting_properties = calculate_monster_starting_properties(breeding_time);
        assert!(*vector::borrow(&starting_properties, 0) == 21, 2);
        assert!(*vector::borrow(&starting_properties, 1) == 1, 3);
        assert!(*vector::borrow(&starting_properties, 2) == 3, 4);
    }

    #[test]
    fun test_calculate_equipment_starting_properties_sum() {
        let combine_amount = 2;
        let starting_properties_sum = calculate_equipment_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM, 0);

        let combine_amount = 10;
        let starting_properties_sum = calculate_equipment_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == EQUIPMENT_MAXIMAL_START_PROPERTY_VALUES_SUM, 1);

        let combine_amount = 6;
        let starting_properties_sum = calculate_equipment_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == 32, 2);
    }

    #[test]
    fun test_combine_properties() {
        let property_keys = vector[
            string::utf8(b"First key"),
            string::utf8(b"Second key"),
            string::utf8(b"Third key"),
            string::utf8(b"Fourth key"),
            string::utf8(b"Fifth key")
        ];
        let property_types = vector[
            string::utf8(b"u64"),
            string::utf8(b"u64"),
            string::utf8(b"0x1::string::String"),
            string::utf8(b"address"),
            string::utf8(b"u64")
        ];
        let property_maps = vector[
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&150),
                    bcs::to_bytes(&46),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&45),
                    bcs::to_bytes(&11),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&846),
                    bcs::to_bytes(&5),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
        ];
        let creator = account::create_account_for_test(@0xCAFE);
        let property_map_objects = vector::map(property_maps, |property_map| {
            let creation_number = account::get_guid_next_creation_num(@0xCAFE);
            let constructor_ref = object::create_object_from_account(&creator);
            property_map::init(&constructor_ref, property_map);

            let property_map_address = object::create_guid_object_address(@0xCAFE, creation_number);
            object::address_to_object<PropertyMap>(property_map_address)
        });

        let combined_properties = combine_properties(property_keys, property_map_objects);
        assert!(vector::length(&combined_properties) == vector::length(&property_keys), 0);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 0)) == 1041, 1);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 1)) == 62, 2);
        assert!(
            from_bcs::to_string(*vector::borrow(&combined_properties, 2)) ==
                string::utf8(b"Random ability"),
            3
        );
        assert!(from_bcs::to_address(*vector::borrow(&combined_properties, 3)) == @0xACE, 4);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 4)) == 333, 5);
    }

    #[test]
    fun test_init() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(simple_map::length(&state.combiner.collections) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 0, 3);
        assert!(event::counter(&state.breeder.create_monster_events) == 0, 4);
        assert!(event::counter(&state.breeder.breed_monster_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 6);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 0, 7);
        assert!(event::counter(&state.combiner.create_equipment_events) == 0, 8);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 9);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 10);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_init_signer_not_admin() {
        let account = account::create_account_for_test(@0xACE);
        init(&account);
    }

    #[test]
    #[expected_failure(abort_code = 524303, location = aptos_framework::account)]
    fun test_init_resource_account_already_exists() {
        let admin = account::create_account_for_test(@admin);
        init(&admin);
        init(&admin);
    }

    #[test]
    fun test_create_monster_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Monster collection");
        let description = string::utf8(b"This is a monster collection");
        let uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(&account, name, description, uri, breeding_time, ability_property);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_monster_events) == 0, 4);
        assert!(event::counter(&state.breeder.breed_monster_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 10);

        let monster_race = simple_map::borrow(&state.breeder.collections, &name);
        assert!(monster_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(monster_race.starting_properties == expected_starting_properties, 12);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_monster_collection_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Monster collection");
        let description = string::utf8(b"This is a monster collection");
        let uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_monster_collection_incorrect_breeding_time_too_small() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Monster collection");
        let description = string::utf8(b"This is a monster collection");
        let uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_monster_collection_incorrect_breeding_time_too_big() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Monster collection");
        let description = string::utf8(b"This is a monster collection");
        let uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 5646851151;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_create_monster_collection_already_exists() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Monster collection");
        let description = string::utf8(b"This is a monster collection");
        let uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 13;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(&account, name, description, uri, breeding_time, ability_property);
        create_monster_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    fun test_create_equipment_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Equipment collection");
        let description = string::utf8(b"This is a equipment collection");
        let uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_monster_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &name), 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 10);

        let equipment = simple_map::borrow(&state.combiner.collections, &name);
        assert!(equipment.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(equipment.starting_properties == expected_starting_properties, 12);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_equipment_collection_incorrect_combine_amount_too_small() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Equipment collection");
        let description = string::utf8(b"This is a equipment collection");
        let uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 1;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_equipment_collection_incorrect_combine_amount_too_big() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Equipment collection");
        let description = string::utf8(b"This is a equipment collection");
        let uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 2222;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_create_equipment_collection_incorrect_property_values_sum() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Equipment collection");
        let description = string::utf8(b"This is a equipment collection");
        let uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 55, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_equipment_collection_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Equipment collection");
        let description = string::utf8(b"This is a equipment collection");
        let uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 3];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_create_equipment_collection_already_exists() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Equipment collection");
        let description = string::utf8(b"This is a equipment collection");
        let uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 3];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
        create_equipment_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    fun test_create_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number = account::get_guid_next_creation_num(resource_account_address);

        let monster_name = string::utf8(b"The first monster");
        let monster_description = string::utf8(b"This is the very first monster in this collection");
        let monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, monster_name, monster_description, monster_uri);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_monster_events) == 1, 4);
        assert!(event::counter(&state.breeder.breed_monster_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 10);

        let monster_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(monster_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(monster_race.starting_properties == expected_starting_properties, 12);

        let token_address = object::create_guid_object_address(resource_account_address, creation_number);
        let token_object = object::address_to_object<Token>(token_address);
        assert!(!aptos_token::are_properties_mutable(token_object), 13);
        assert!(!aptos_token::is_burnable(token_object), 14);
        assert!(aptos_token::is_freezable_by_creator(token_object), 15);
        assert!(!aptos_token::is_mutable_description(token_object), 16);
        assert!(!aptos_token::is_mutable_name(token_object), 17);
        assert!(!aptos_token::is_mutable_uri(token_object), 18);
        assert!(token::creator(token_object) == resource_account_address, 19);
        assert!(token::collection_name(token_object) == collection_name, 20);
        assert!(token::description(token_object) == monster_description, 21);
        assert!(token::name(token_object) == monster_name, 22);
        assert!(token::uri(token_object) == monster_uri, 23);

        let maybe_token_royalty = token::royalty(token_object);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_monster_state_not_initalized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let monster_name = string::utf8(b"The first monster");
        let monster_description = string::utf8(b"This is the very first monster in this collection");
        let monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, monster_name, monster_description, monster_uri);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_create_monster_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let monster_name = string::utf8(b"The first monster");
        let monster_description = string::utf8(b"This is the very first monster in this collection");
        let monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, monster_name, monster_description, monster_uri);
    }

    #[test]
    fun test_create_equipment() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let collection_description = string::utf8(b"This is a equipment collection");
        let collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number = account::get_guid_next_creation_num(resource_account_address);

        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 2);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_monster_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &collection_name), 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 1, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 10);

        let equipment = simple_map::borrow(&state.combiner.collections, &collection_name);
        assert!(equipment.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(equipment.starting_properties == expected_starting_properties, 12);

        let counter = 0;
        while (counter <= 1) {
            let token_address =
                object::create_guid_object_address(resource_account_address, creation_number + counter);
            let token_object = object::address_to_object<Token>(token_address);
            assert!(!aptos_token::are_properties_mutable(token_object), 13 + 15 * counter);
            assert!(aptos_token::is_burnable(token_object), 14 + 15 * counter);
            assert!(!aptos_token::is_freezable_by_creator(token_object), 15 + 15 * counter);
            assert!(!aptos_token::is_mutable_description(token_object), 16 + 15 * counter);
            assert!(!aptos_token::is_mutable_name(token_object), 17 + 15 * counter);
            assert!(!aptos_token::is_mutable_uri(token_object), 18 + 15 * counter);
            assert!(token::creator(token_object) == resource_account_address, 19 + 15 * counter);
            assert!(token::collection_name(token_object) == collection_name, 20 + 15 * counter);
            assert!(token::description(token_object) == equipment_description, 21 + 15 * counter);
            assert!(token::name(token_object) == equipment_name, 22 + 15 * counter);
            assert!(token::uri(token_object) == equipment_uri, 23 + 15 * counter);

            let maybe_token_royalty = token::royalty(token_object);
            assert!(option::is_some(&maybe_token_royalty), 24 + 15 * counter);

            let token_royalty = option::extract(&mut maybe_token_royalty);
            assert!(royalty::denominator(&token_royalty) == 10, 25 + 15 * counter);
            assert!(royalty::numerator(&token_royalty) == 1, 26 + 15 * counter);
            assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27 + 15 * counter);

            counter = counter + 1;
        };
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_equipment_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 2);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_create_equipment_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 2);
    }

    #[test]
    fun test_breed_monsters() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        let current_timestamp = timestamp::now_seconds();
        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 1, 2);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_monster_events) == 2, 4);
        assert!(event::counter(&state.breeder.breed_monster_events) == 1, 5);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 10);

        let first_monster_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        let second_monster_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        let breeding_key_bytes = bcs::to_bytes(&first_monster_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_monster_address));

        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);
        assert!(simple_map::contains_key(&state.breeder.ongoing_breedings, &breeding_key), 11);

        let breeding_time =
            simple_map::borrow(&state.breeder.collections, &collection_name).breeding_time;
        let breeding_end = *simple_map::borrow(&state.breeder.ongoing_breedings, &breeding_key);
        let lower_limit = if (current_timestamp > 0) {
            current_timestamp + breeding_time - 1
        } else {
            current_timestamp + breeding_time
        };
        assert!(lower_limit <= breeding_end && breeding_end <= current_timestamp + breeding_time + 1, 12);

        let monster_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(monster_race.breeding_time == breeding_time, 13);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(monster_race.starting_properties == expected_starting_properties, 14);

        let first_monster_token = object::address_to_object<Token>(first_monster_address);
        assert!(!object::ungated_transfer_allowed(first_monster_token), 15);

        let second_monster_token = object::address_to_object<Token>(second_monster_address);
        assert!(!object::ungated_transfer_allowed(second_monster_token), 16);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_breed_monsters_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        breed_monsters(&account, collection_name, 156, 54);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_breed_monsters_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        breed_monsters(&account, collection_name, 156, 54);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_breed_monster_signer_does_not_own_the_first_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        let first_monster_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        object::transfer_raw(&account, first_monster_address, @0xBEEF);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_breed_monster_signer_does_not_own_the_second_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        let second_monster_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        object::transfer_raw(&account, second_monster_address, @0xBEEF);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_breed_monster_first_monster_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let another_collection_name = string::utf8(b"Monster collection 2");
        let another_collection_description = string::utf8(b"This is another monster collection");
        let another_collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let another_breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let another_ability_property = string::utf8(b"BEET");
        create_monster_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_breeding_time,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, another_collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_breed_monster_second_monster_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let another_collection_name = string::utf8(b"Monster collection 2");
        let another_collection_description = string::utf8(b"This is another monster collection");
        let another_collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let another_breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let another_ability_property = string::utf8(b"BEET");
        create_monster_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_breeding_time,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, another_collection_name, second_monster_name, second_monster_description, second_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_breed_monsters_first_monster_already_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);

        let third_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let third_monster_name = string::utf8(b"The third monster");
        let third_monster_description = string::utf8(b"This is another monster in this collection");
        let third_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, third_monster_name, third_monster_description, third_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, third_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_breed_monsters_second_monster_already_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);

        let third_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let third_monster_name = string::utf8(b"The third monster");
        let third_monster_description = string::utf8(b"This is another monster in this collection");
        let third_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, third_monster_name, third_monster_description, third_monster_uri);

        breed_monsters(&account, collection_name, third_creation_number, second_creation_number);
    }

    #[test]
    fun test_hatch_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);
        timestamp::fast_forward_seconds(breeding_time);

        let new_monster_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let new_monster_name = string::utf8(b"Baby monster");
        let new_monster_description = string::utf8(b"This is a newly born baby monster!");
        let new_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        hatch_monster(
            &account,
            first_creation_number,
            second_creation_number,
            new_monster_name,
            new_monster_description,
            new_monster_uri
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_monster_events) == 2, 4);
        assert!(event::counter(&state.breeder.breed_monster_events) == 1, 5);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 1, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 0, 10);

        let monster_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(monster_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(monster_race.starting_properties == expected_starting_properties, 12);

        let first_monster_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        let first_monster_token = object::address_to_object<Token>(first_monster_address);
        assert!(object::ungated_transfer_allowed(first_monster_token), 13);

        let second_monster_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        let second_monster_token = object::address_to_object<Token>(second_monster_address);
        assert!(object::ungated_transfer_allowed(second_monster_token), 14);

        let new_monster_address =
            object::create_guid_object_address(resource_account_address, new_monster_creation_number);
        let new_monster_token = object::address_to_object<Token>(new_monster_address);
        assert!(!aptos_token::are_properties_mutable(new_monster_token), 15);
        assert!(!aptos_token::is_burnable(new_monster_token), 16);
        assert!(aptos_token::is_freezable_by_creator(new_monster_token), 17);
        assert!(!aptos_token::is_mutable_description(new_monster_token), 18);
        assert!(!aptos_token::is_mutable_name(new_monster_token), 19);
        assert!(!aptos_token::is_mutable_uri(new_monster_token), 20);
        assert!(token::creator(new_monster_token) == resource_account_address, 21);
        assert!(token::collection_name(new_monster_token) == collection_name, 22);
        assert!(token::description(new_monster_token) == new_monster_description, 23);
        assert!(token::name(new_monster_token) == new_monster_name, 24);
        assert!(token::uri(new_monster_token) == new_monster_uri, 25);

        let maybe_token_royalty = token::royalty(new_monster_token);
        assert!(option::is_some(&maybe_token_royalty), 26);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 27);
        assert!(royalty::numerator(&token_royalty) == 1, 28);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 29);

        let property_map = object::address_to_object<PropertyMap>(new_monster_address);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Health")) == 80, 30);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Defence")) == 6, 31);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Strength")) == 14, 32);
        assert!(
            property_map::read_string(&property_map, &string::utf8(b"Ability")) == ability_property,
            33
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_hatch_monster_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let new_monster_name = string::utf8(b"Baby monster");
        let new_monster_description = string::utf8(b"This is a newly born baby monster!");
        let new_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        hatch_monster(
            &account,
            11,
            15,
            new_monster_name,
            new_monster_description,
            new_monster_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_hatch_monster_signer_not_owner_first_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        let first_monster_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        object::transfer_raw(&account, first_monster_address, @0xABC);

        let new_monster_name = string::utf8(b"Baby monster");
        let new_monster_description = string::utf8(b"This is a newly born baby monster!");
        let new_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        hatch_monster(
            &account,
            first_creation_number,
            second_creation_number,
            new_monster_name,
            new_monster_description,
            new_monster_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_hatch_monster_signer_not_owner_second_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        let second_monster_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        object::transfer_raw(&account, second_monster_address, @0xABC);

        let new_monster_name = string::utf8(b"Baby monster");
        let new_monster_description = string::utf8(b"This is a newly born baby monster!");
        let new_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        hatch_monster(
            &account,
            first_creation_number,
            second_creation_number,
            new_monster_name,
            new_monster_description,
            new_monster_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 9, location = Self)]
    fun test_hatch_monsters_not_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        let new_monster_name = string::utf8(b"Baby monster");
        let new_monster_description = string::utf8(b"This is a newly born baby monster!");
        let new_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        hatch_monster(
            &account,
            first_creation_number,
            second_creation_number,
            new_monster_name,
            new_monster_description,
            new_monster_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_hatch_monster_breeding_not_finished() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Monster collection");
        let collection_description = string::utf8(b"This is a monster collection");
        let collection_uri =
            string::utf8(b"https://upload.wikimedia.org/wikipedia/commons/2/24/Monster_Energy_sold_in_China.jpg");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_monster_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_monster_name = string::utf8(b"The first monster");
        let first_monster_description = string::utf8(b"This is the very first monster in this collection");
        let first_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, first_monster_name, first_monster_description, first_monster_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_monster_name = string::utf8(b"The second monster");
        let second_monster_description = string::utf8(b"This is another monster in this collection");
        let second_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        create_monster(&account, collection_name, second_monster_name, second_monster_description, second_monster_uri);

        breed_monsters(&account, collection_name, first_creation_number, second_creation_number);

        let new_monster_name = string::utf8(b"Baby monster");
        let new_monster_description = string::utf8(b"This is a newly born baby monster!");
        let new_monster_uri = string::utf8(b"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQy9fkzKQ1xcpJgK_ZlsDg1mFRUL64Rk1bzmjiZdqdpufyo4z41QRvRteq-M8PzVJXM_Mc&usqp=CAU");
        hatch_monster(
            &account,
            first_creation_number,
            second_creation_number,
            new_monster_name,
            new_monster_description,
            new_monster_uri
        );
    }

    #[test]
    fun test_combine_equipment() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let collection_description = string::utf8(b"This is a equipment collection");
        let collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number_brefore_first_creation = account::get_guid_next_creation_num(resource_account_address);

        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 2);

        let creation_number_brefore_second_creation =
            account::get_guid_next_creation_num(resource_account_address);
        let equipment_name = string::utf8(b"The Great Spork");
        let equipment_description = string::utf8(b"For a true taster");
        let equipment_uri =
            string::utf8(b"https://www.watchuseek.com/attachments/spork-notes-1-jpg.532357/");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 2);

        let new_equipment_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let new_equipment_name = string::utf8(b"Ultimate Cutlery");
        let new_equipment_description = string::utf8(b"For a true Gourmet");
        let new_equipment_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_equipment(
            &account,
            collection_name,
            vector[
                creation_number_brefore_first_creation,
                creation_number_brefore_first_creation + 1,
                creation_number_brefore_second_creation,
                creation_number_brefore_second_creation + 1
            ],
            new_equipment_name,
            new_equipment_description,
            new_equipment_uri
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_monster_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_monster_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_monster_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_monster_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &collection_name), 7);
        assert!(event::counter(&state.combiner.create_equipment_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_equipment_events) == 2, 9);
        assert!(event::counter(&state.combiner.combine_equipment_events) == 1, 10);

        let equipment = simple_map::borrow(&state.combiner.collections, &collection_name);
        assert!(equipment.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(equipment.starting_properties == expected_starting_properties, 12);

        let new_equipment_address =
            object::create_guid_object_address(resource_account_address, new_equipment_creation_number);
        let new_equipment_token = object::address_to_object<Token>(new_equipment_address);
        assert!(!aptos_token::are_properties_mutable(new_equipment_token), 13);
        assert!(aptos_token::is_burnable(new_equipment_token), 14);
        assert!(!aptos_token::is_freezable_by_creator(new_equipment_token), 15);
        assert!(!aptos_token::is_mutable_description(new_equipment_token), 16);
        assert!(!aptos_token::is_mutable_name(new_equipment_token), 17);
        assert!(!aptos_token::is_mutable_uri(new_equipment_token), 18);
        assert!(token::creator(new_equipment_token) == resource_account_address, 19);
        assert!(token::collection_name(new_equipment_token) == collection_name, 20);
        assert!(token::description(new_equipment_token) == new_equipment_description, 21);
        assert!(token::name(new_equipment_token) == new_equipment_name, 22);
        assert!(token::uri(new_equipment_token) == new_equipment_uri, 23);

        let maybe_token_royalty = token::royalty(new_equipment_token);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);

        let property_map = object::address_to_object<PropertyMap>(new_equipment_address);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Attack")) == 40, 28);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Defence")) == 0, 29);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Durability")) == 20, 30);
        assert!(
            property_map::read_string(&property_map, &string::utf8(b"Ability")) ==
                string::utf8(b"Fire imbued"),
            31
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_combine_equipment_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let new_equipment_name = string::utf8(b"Ultimate Cutlery");
        let new_equipment_description = string::utf8(b"For a true Gourmet");
        let new_equipment_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_equipment(
            &account,
            collection_name,
            vector[15, 16, 55, 66],
            new_equipment_name,
            new_equipment_description,
            new_equipment_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 11, location = Self)]
    fun test_combine_equipment_incorrect_amount_of_equipment() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let collection_description = string::utf8(b"This is a equipment collection");
        let collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let new_equipment_name = string::utf8(b"Ultimate Cutlery");
        let new_equipment_description = string::utf8(b"For a true Gourmet");
        let new_equipment_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_equipment(
            &account,
            collection_name,
            vector[15],
            new_equipment_name,
            new_equipment_description,
            new_equipment_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_combine_equipment_signer_does_not_own_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let collection_description = string::utf8(b"This is a equipment collection");
        let collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let creation_number = account::get_guid_next_creation_num(resource_account_address);
        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 4);

        let equipment_address =
            object::create_guid_object_address(resource_account_address, creation_number + 1);
        object::transfer_raw(&account, equipment_address, @0xABCDEF);

        let new_equipment_name = string::utf8(b"Ultimate Cutlery");
        let new_equipment_description = string::utf8(b"For a true Gourmet");
        let new_equipment_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_equipment(
            &account,
            collection_name,
            vector[
                creation_number,
                creation_number + 1,
                creation_number + 2,
                creation_number + 3
            ],
            new_equipment_name,
            new_equipment_description,
            new_equipment_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_combine_equipment_token_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Equipment collection");
        let collection_description = string::utf8(b"This is a equipment collection");
        let collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let combine_amount = 4;
        let property_values = vector[10, 0, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_equipment_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let another_collection_name = string::utf8(b"Equipment collection 2");
        let another_collection_description = string::utf8(b"This is another equipment collection");
        let another_collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let another_combine_amount = 4;
        let another_property_values = vector[10, 0, 5];
        let another_ability_property = string::utf8(b"Ice imbued");
        create_equipment_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_combine_amount,
            another_property_values,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let creation_number = account::get_guid_next_creation_num(resource_account_address);
        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, collection_name, equipment_name, equipment_description, equipment_uri, 3);

        let equipment_name = string::utf8(b"Eggscalibur");
        let equipment_description = string::utf8(b"For a true chef");
        let equipment_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_equipment(&account, another_collection_name, equipment_name, equipment_description, equipment_uri, 1);

        let new_equipment_name = string::utf8(b"Ultimate Cutlery");
        let new_equipment_description = string::utf8(b"For a true Gourmet");
        let new_equipment_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_equipment(
            &account,
            collection_name,
            vector[
                creation_number,
                creation_number + 3,
                creation_number + 2,
                creation_number + 1
            ],
            new_equipment_name,
            new_equipment_description,
            new_equipment_uri
        );
    }
}