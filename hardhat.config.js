require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
        { 
          version: "0.5.16",
          settings:{
            optimizer:{
              enabled: true,
              runs: 200
            }
          }
        },
        { 
          version: "0.8.10",
          settings:{
            optimizer:{
              enabled: true,
              runs: 200
            }
          }
        }
      ]
    }    
};
