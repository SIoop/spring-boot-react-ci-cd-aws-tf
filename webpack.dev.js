const common = require('./webpack.common.js');
const { merge } = require('webpack-merge');
var path = require('path');
const CopyWebpackPlugin = require('copy-webpack-plugin');

module.exports = merge(common, {
    mode: 'development',
    devtool: 'sourcemaps',
    cache: true,
    output: {
        path: __dirname,
        filename: './build/bundle.js'
    },
    plugins: [
    
        // Copies static assets like CSS
        new CopyWebpackPlugin({
          patterns: [
            { from: path.resolve(__dirname, 'src/main/resources/static/*.css')}, // Moves CSS to /build/
            { from: path.resolve(__dirname, 'src/main/resources/templates/*.html')}, // Moves HTML to /build/
          ],
        }),
      ],
});